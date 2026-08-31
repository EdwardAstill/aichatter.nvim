local h = require("tests.helpers")
local path = require("aichatter.path")
local Shadow = require("aichatter.shadow")

local uv = vim.uv

local function uv_with(overrides)
  return setmetatable(overrides or {}, { __index = uv })
end

local function wait_result(start)
  local calls, failure, value = 0
  start(function(err, result)
    calls = calls + 1
    failure, value = err, result
  end)
  h.truthy(h.wait_for(function() return calls > 0 end, 3000))
  vim.wait(20)
  h.eq(1, calls)
  return failure, value
end

local function wait_error(start)
  local err = wait_result(start)
  return err
end

local function same_argv(expected, actual)
  h.eq(vim.inspect(expected), vim.inspect(actual))
end

h.test("creates separate baseline and workspace with unsaved buffer content", function()
  local root = h.tempdir()
  local temp_parent = h.tempdir()
  h.write(root .. "/main.lua", "return 1\n")

  local shadow = h.create_shadow(root, {
    temp_parent = temp_parent,
    buffer_provider = function(provider_root)
      h.eq(root, provider_root)
      return { { path = root .. "/main.lua", bytes = "return 2\n", mode = 420 } }
    end,
  })

  h.truthy(path.is_within(temp_parent, shadow.session_root))
  h.matches("^aichatter%-", vim.fs.basename(shadow.session_root))
  h.eq(shadow.session_root .. "/control/baseline", shadow.baseline_root)
  h.eq(shadow.session_root .. "/workspace", shadow.workspace_root)
  h.eq("return 2\n", h.read(shadow.baseline_root .. "/main.lua"))
  h.eq("return 2\n", h.read(shadow.workspace_root .. "/main.lua"))
  h.eq("return 1\n", h.read(root .. "/main.lua"))
end)

h.test("canonicalizes a symlinked temp parent and creates a private random session", function()
  local root = h.tempdir()
  local parent_container = h.tempdir()
  local actual_parent = parent_container .. "/actual"
  local linked_parent = parent_container .. "/linked"
  h.mkdir(actual_parent)
  h.symlink(actual_parent, linked_parent)
  h.write(root .. "/main.lua", "return 1\n")

  local shadow = h.create_shadow(root, { temp_parent = linked_parent })
  local basename = vim.fs.basename(shadow.session_root)

  h.truthy(path.is_within(actual_parent, shadow.session_root))
  h.eq(actual_parent, shadow._temp_parent)
  h.eq(448, bit.band(assert(uv.fs_lstat(shadow.session_root)).mode, 511))
  h.matches("^aichatter%-%x+$", basename)
  h.falsy(basename:match("^aichatter%-%d+%-%d+$"))
end)

h.test("uses exact independent-clone arguments and overlays dirty untracked and ignored files", function()
  local root = h.git_project({
    [".gitignore"] = "ignored.bin\n",
    ["tracked.txt"] = "base\n",
  })
  h.write(root .. "/tracked.txt", "dirty\n")
  h.write(root .. "/untracked.txt", "untracked\n")
  h.write(root .. "/ignored.bin", "dependency\n")
  local git_index_before = h.read(root .. "/.git/index")
  local calls = {}
  local function run(argv, callback)
    calls[#calls + 1] = vim.deepcopy(argv)
    return vim.system(argv, { text = true }, function(result)
      callback(nil, result)
    end)
  end

  local shadow = h.create_shadow(root, { run = run })

  same_argv({ "git", "-C", root, "rev-parse", "--is-inside-work-tree" }, calls[1])
  same_argv({
    "git", "clone", "--local", "--no-hardlinks", "--", root, shadow.workspace_root,
  }, calls[2])
  h.eq("dirty\n", h.read(shadow.workspace_root .. "/tracked.txt"))
  h.eq("untracked\n", h.read(shadow.workspace_root .. "/untracked.txt"))
  h.eq("dependency\n", h.read(shadow.workspace_root .. "/ignored.bin"))
  h.eq("dirty\n", h.read(shadow.baseline_root .. "/tracked.txt"))
  h.eq(nil, uv.fs_lstat(shadow.baseline_root .. "/.git"))
  h.truthy(uv.fs_lstat(shadow.workspace_root .. "/.git"))
  h.falsy(path.is_within(root .. "/.git", shadow.workspace_root .. "/.git"))
  h.eq(git_index_before, h.read(root .. "/.git/index"))
  h.eq("dirty\n", h.read(root .. "/tracked.txt"))
end)

h.test("discovers a real Git root from a nested working directory", function()
  local root = h.git_project({ ["nested/child.txt"] = "child\n" })

  local shadow = h.create_shadow(root .. "/nested")

  h.eq(root, shadow.project_root)
  h.eq("child\n", h.read(shadow.workspace_root .. "/nested/child.txt"))
end)

h.test("clones a real linked worktree into independent Git metadata", function()
  local root = h.git_project({ ["tracked.txt"] = "tracked\n" })
  local linked = h.tempdir() .. "/linked-worktree"
  local added = vim.system({ "git", "-C", root, "worktree", "add", "--detach", linked },
    { text = true }):wait()
  h.eq(0, added.code)

  local shadow = h.create_shadow(linked)

  h.eq(linked, shadow.project_root)
  h.eq("directory", assert(uv.fs_lstat(shadow.workspace_root .. "/.git")).type)
  h.eq("tracked\n", h.read(shadow.workspace_root .. "/tracked.txt"))
end)

h.test("real local clone objects do not share device and inode identity", function()
  local root = h.git_project({ ["tracked.txt"] = "tracked\n" })
  local object = vim.trim(vim.system({ "git", "-C", root, "rev-parse", "HEAD" },
    { text = true }):wait().stdout)
  local relative = "objects/" .. object:sub(1, 2) .. "/" .. object:sub(3)

  local shadow = h.create_shadow(root)
  local source = assert(uv.fs_stat(root .. "/.git/" .. relative))
  local cloned = assert(uv.fs_stat(shadow.workspace_root .. "/.git/" .. relative))

  h.falsy(source.dev == cloned.dev and source.ino == cloned.ino)
end)

h.test("default buffer overlay preserves an unsaved missing final newline", function()
  local root = h.tempdir()
  local source = root .. "/note.txt"
  h.write(source, "disk\n")
  h.chmod(source, 416)
  local bufnr = vim.fn.bufadd(source)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved", "tail" })
  vim.bo[bufnr].endofline = false
  vim.bo[bufnr].modified = true

  local shadow = h.create_shadow(root)

  h.eq("unsaved\ntail", h.read(shadow.baseline_root .. "/note.txt"))
  h.eq("unsaved\ntail", h.read(shadow.workspace_root .. "/note.txt"))
  h.eq(416, bit.band(uv.fs_stat(shadow.workspace_root .. "/note.txt").mode, 511))
  h.eq("disk\n", h.read(source))
  h.truthy(vim.bo[bufnr].modified)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("default buffer overlay preserves a loaded zero-byte file exactly", function()
  local root = h.tempdir()
  local source = root .. "/empty.txt"
  h.write(source, "")
  local bufnr = vim.fn.bufadd(source)
  vim.fn.bufload(bufnr)
  h.eq({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].endofline)

  local shadow = h.create_shadow(root)

  h.eq("", h.read(shadow.baseline_root .. "/empty.txt"))
  h.eq("", h.read(shadow.workspace_root .. "/empty.txt"))
  h.eq("", h.read(source))
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("preserves symlinks in workspace and metadata-free baseline", function()
  local root = h.tempdir()
  local outside = h.tempdir()
  h.write(root .. "/target.txt", "inside\n")
  h.write(outside .. "/external.txt", "outside\n")
  h.symlink("target.txt", root .. "/internal-link")
  h.symlink(outside .. "/external.txt", root .. "/external-link")

  local shadow = h.create_shadow(root)

  for _, destination in ipairs({ shadow.workspace_root, shadow.baseline_root }) do
    h.eq("link", uv.fs_lstat(destination .. "/internal-link").type)
    h.eq("target.txt", uv.fs_readlink(destination .. "/internal-link"))
    h.eq("link", uv.fs_lstat(destination .. "/external-link").type)
    h.eq(outside .. "/external.txt", uv.fs_readlink(destination .. "/external-link"))
  end
end)

h.test("rejects buffer paths through symlink ancestors without changing external bytes", function()
  local parent = h.tempdir()
  local root = parent .. "/actual"
  local alias = parent .. "/alias"
  local outside = h.tempdir()
  h.mkdir(root)
  h.write(outside .. "/victim.txt", "external\n")
  h.symlink(outside, root .. "/linked")
  h.symlink(root, alias)

  local err, shadow = wait_result(function(callback)
    Shadow.create({
      root = alias,
      temp_parent = h.tempdir(),
      buffer_provider = function()
        return {
          { path = alias .. "/linked/victim.txt", bytes = "overwritten\n", mode = 420 },
        }
      end,
    }, callback)
  end)

  h.truthy(err)
  h.eq(nil, shadow)
  h.matches("symlink ancestor", err.message)
  h.eq("external\n", h.read(outside .. "/victim.txt"))
end)

h.test("resolves a symlinked project root before mirroring", function()
  local parent = h.tempdir()
  local actual = parent .. "/actual"
  local linked = parent .. "/linked-root"
  h.mkdir(actual)
  h.write(actual .. "/main.lua", "return 1\n")
  h.symlink(actual, linked)

  local shadow = h.create_shadow(linked)

  h.eq(actual, shadow.project_root)
  h.eq("directory", uv.fs_lstat(shadow.workspace_root).type)
  h.eq("directory", uv.fs_lstat(shadow.baseline_root).type)
  h.eq("return 1\n", h.read(shadow.workspace_root .. "/main.lua"))
end)

h.test("overlays a loaded unsaved buffer named through the project root alias", function()
  local parent = h.tempdir()
  local actual = parent .. "/actual"
  local alias = parent .. "/alias"
  h.mkdir(actual)
  h.write(actual .. "/note.txt", "disk\n")
  h.symlink(actual, alias)
  local bufnr = vim.fn.bufadd(actual .. "/note.txt")
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved alias" })
  vim.bo[bufnr].endofline = false
  vim.bo[bufnr].modified = true
  local get_name = vim.api.nvim_buf_get_name
  vim.api.nvim_buf_get_name = function(current)
    if current == bufnr then
      return alias .. "/note.txt"
    end
    return get_name(current)
  end

  local created, shadow = xpcall(function()
    return h.create_shadow(alias)
  end, debug.traceback)
  vim.api.nvim_buf_get_name = get_name
  assert(created, shadow)

  h.eq("unsaved alias", h.read(shadow.workspace_root .. "/note.txt"))
  h.eq("unsaved alias", h.read(shadow.baseline_root .. "/note.txt"))
  h.eq("disk\n", h.read(actual .. "/note.txt"))
  h.truthy(vim.bo[bufnr].modified)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("retains an absolute excluded proposal named through the project root alias", function()
  local parent = h.tempdir()
  local actual = parent .. "/actual"
  local alias = parent .. "/alias"
  h.mkdir(actual)
  h.write(actual .. "/proposal.txt", "shadow proposal\n")
  h.write(actual .. "/ordinary.txt", "old\n")
  h.symlink(actual, alias)
  local shadow = h.create_shadow(alias)
  h.write(actual .. "/proposal.txt", "live proposal\n")
  h.write(actual .. "/ordinary.txt", "fresh\n")

  local err = wait_error(function(callback)
    shadow:sync_live({ [alias .. "/proposal.txt"] = true }, callback)
  end)

  h.eq(nil, err)
  for _, destination in ipairs({ shadow.workspace_root, shadow.baseline_root }) do
    h.eq("shadow proposal\n", h.read(destination .. "/proposal.txt"))
    h.eq("fresh\n", h.read(destination .. "/ordinary.txt"))
  end
end)

h.test("canonicalizes relative exclusions and rejects escapes", function()
  local root = h.tempdir()
  h.mkdir(root .. "/dir")
  h.write(root .. "/proposal.txt", "shadow proposal\n")
  h.write(root .. "/ordinary.txt", "old\n")
  local shadow = h.create_shadow(root)
  h.write(root .. "/proposal.txt", "live proposal\n")
  h.write(root .. "/ordinary.txt", "fresh\n")

  local err = wait_error(function(callback)
    shadow:sync_live({ ["dir/../proposal.txt"] = true }, callback)
  end)
  h.eq(nil, err)
  h.eq("shadow proposal\n", h.read(shadow.workspace_root .. "/proposal.txt"))
  h.eq("fresh\n", h.read(shadow.workspace_root .. "/ordinary.txt"))

  local escape = wait_error(function(callback)
    shadow:sync_live({ ["../outside"] = true }, callback)
  end)
  h.eq("outside_root", escape.code)
end)

h.test("sync_live updates both trees while retaining excluded proposals", function()
  local root = h.tempdir()
  h.write(root .. "/proposal.txt", "shadow proposal\n")
  h.write(root .. "/ordinary.txt", "old\n")
  local shadow = h.create_shadow(root)
  h.write(root .. "/proposal.txt", "live proposal\n")
  h.write(root .. "/ordinary.txt", "fresh\n")

  local err = wait_error(function(callback)
    shadow:sync_live({ ["proposal.txt"] = true }, callback)
  end)

  h.eq(nil, err)
  for _, destination in ipairs({ shadow.workspace_root, shadow.baseline_root }) do
    h.eq("shadow proposal\n", h.read(destination .. "/proposal.txt"))
    h.eq("fresh\n", h.read(destination .. "/ordinary.txt"))
  end
  h.eq("live proposal\n", h.read(root .. "/proposal.txt"))
end)

h.test("sync_live prunes deleted files directories and symlinks but retains exclusions", function()
  local root = h.git_project({
    ["deleted-file.txt"] = "file\n",
    ["deleted-dir/child.txt"] = "child\n",
    ["keep.txt"] = "keep\n",
    ["proposal.txt"] = "proposal\n",
    ["proposal-dir/child.txt"] = "nested proposal\n",
    ["proposal-dir/remove.txt"] = "remove me\n",
  })
  h.symlink("keep.txt", root .. "/deleted-link")
  local shadow = h.create_shadow(root)
  vim.fn.delete(root .. "/deleted-file.txt")
  vim.fn.delete(root .. "/deleted-dir", "rf")
  vim.fn.delete(root .. "/deleted-link")
  vim.fn.delete(root .. "/proposal.txt")
  vim.fn.delete(root .. "/proposal-dir", "rf")

  local err = wait_error(function(callback)
    shadow:sync_live({
      ["proposal.txt"] = true,
      ["proposal-dir/child.txt"] = true,
    }, callback)
  end)

  h.eq(nil, err)
  for _, destination in ipairs({ shadow.workspace_root, shadow.baseline_root }) do
    h.eq(nil, uv.fs_lstat(destination .. "/deleted-file.txt"))
    h.eq(nil, uv.fs_lstat(destination .. "/deleted-dir"))
    h.eq(nil, uv.fs_lstat(destination .. "/deleted-link"))
    h.eq("proposal\n", h.read(destination .. "/proposal.txt"))
    h.eq("nested proposal\n", h.read(destination .. "/proposal-dir/child.txt"))
    h.eq(nil, uv.fs_lstat(destination .. "/proposal-dir/remove.txt"))
  end
  h.truthy(uv.fs_lstat(shadow.workspace_root .. "/.git"))
  h.eq(nil, uv.fs_lstat(shadow.baseline_root .. "/.git"))
end)

h.test("returns structured argv exit and stderr on clone failure", function()
  local root = h.tempdir()
  local clone_argv
  local calls = 0
  local function run(argv, callback)
    calls = calls + 1
    if calls == 1 then
      callback(nil, { code = 0, stdout = "true\n", stderr = "" })
    else
      clone_argv = vim.deepcopy(argv)
      callback(nil, { code = 37, stdout = "", stderr = "clone exploded\n" })
    end
  end

  local err = wait_error(function(callback)
    Shadow.create({ root = root, temp_parent = h.tempdir(), run = run }, callback)
  end)

  h.eq(37, err.code)
  h.eq("clone exploded\n", err.stderr)
  h.eq(vim.inspect(clone_argv), vim.inspect(err.argv))
  h.matches("git clone failed", err.message)
end)

h.test("cleans a partially allocated session when control directory creation fails", function()
  local temp_parent = h.tempdir()
  local mkdir_calls = 0
  local session_root
  local Isolated = Shadow._new({
    uv = uv_with({
      fs_mkdir = function(target, mode)
        mkdir_calls = mkdir_calls + 1
        if mkdir_calls == 1 then
          session_root = target
          return uv.fs_mkdir(target, mode)
        end
        return nil, "injected control failure", "EIO"
      end,
    }),
  })

  local err = wait_error(function(callback)
    Isolated.create({ root = h.tempdir(), temp_parent = temp_parent }, callback)
  end)

  h.eq("EIO", err.code)
  h.matches("injected control failure", err.message)
  h.eq(nil, uv.fs_lstat(session_root))
end)

h.test("cleanup cancels outstanding sync and removes the session exactly once", function()
  local pending
  local remove_calls = 0
  local hold_copies = false
  local fake_fs = {
    copy_tree = function(_, target, opts, callback)
      if hold_copies then
        pending = { cancel = opts.cancel, callback = callback }
      else
        h.mkdir(target)
        callback()
      end
    end,
    atomic_write = function(_, _, _, callback) callback() end,
    remove_tree_guarded = function(_, _, _, callback)
      remove_calls = remove_calls + 1
      callback()
    end,
  }
  local Isolated = Shadow._new({ fs = fake_fs })
  local root = h.tempdir()
  h.write(root .. "/a.txt", "one\n")
  local err, shadow = wait_result(function(callback)
    Isolated.create({
      root = root,
      temp_parent = h.tempdir(),
      run = function(_, done) done(nil, { code = 1, stderr = "not git" }) end,
      buffer_provider = function() return {} end,
    }, callback)
  end)
  h.eq(nil, err)
  hold_copies = true
  local sync_calls, cleanup_calls = 0, 0
  shadow:sync_live({}, function(sync_err)
    sync_calls = sync_calls + 1
    h.eq("cancelled", sync_err.code)
  end)
  shadow:cleanup(function() cleanup_calls = cleanup_calls + 1 end)
  shadow:cleanup(function() cleanup_calls = cleanup_calls + 1 end)

  h.truthy(pending.cancel.cancelled)
  h.eq(0, remove_calls)
  pending.callback({ code = "cancelled", message = "copy cancelled" })

  h.eq(1, sync_calls)
  h.eq(1, remove_calls)
  h.eq(2, cleanup_calls)
  shadow:cleanup(function() cleanup_calls = cleanup_calls + 1 end)
  h.eq(1, remove_calls)
  h.eq(3, cleanup_calls)
end)

local function fake_shadow(buffer_provider)
  local remove_calls = 0
  local fake_fs = {
    copy_tree = function(_, target, _, callback)
      h.mkdir(target)
      callback()
    end,
    atomic_write = function(_, _, _, callback) callback() end,
    remove_tree_guarded = function(_, _, _, callback)
      remove_calls = remove_calls + 1
      callback()
    end,
  }
  local Isolated = Shadow._new({ fs = fake_fs })
  local err, shadow = wait_result(function(callback)
    Isolated.create({
      root = h.tempdir(),
      temp_parent = h.tempdir(),
      run = function(_, done) done(nil, { code = 1, stderr = "not git" }) end,
      buffer_provider = buffer_provider or function() return {} end,
    }, callback)
  end)
  h.eq(nil, err)
  return shadow, function() return remove_calls end
end

h.test("throwing sync callback cannot strand cleanup activity", function()
  local shadow, remove_calls = fake_shadow()

  shadow:sync_live({}, function() error("injected sync callback failure") end)
  shadow:cleanup()

  h.eq(1, remove_calls())
end)

h.test("throwing buffer callback cannot strand cleanup activity", function()
  local enabled = false
  local root
  local shadow, remove_calls = fake_shadow(function()
    if not enabled then
      return {}
    end
    return { { path = root .. "/new.txt", bytes = "buffer\n", mode = 420 } }
  end)
  root = shadow.project_root
  enabled = true

  shadow:overlay_buffers(function() error("injected buffer callback failure") end)
  shadow:cleanup()

  h.eq(1, remove_calls())
end)
