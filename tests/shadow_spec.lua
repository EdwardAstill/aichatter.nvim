local h = require("tests.helpers")
local path = require("aichatter.path")
local Shadow = require("aichatter.shadow")

local uv = vim.uv

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

h.test("cleanup cancels outstanding sync and removes the session exactly once", function()
  local pending
  local remove_calls = 0
  local hold_copies = false
  local fake_fs = {
    copy_tree = function(_, _, opts, callback)
      if hold_copies then
        pending = { cancel = opts.cancel, callback = callback }
      else
        callback()
      end
    end,
    atomic_write = function(_, _, _, callback) callback() end,
    remove_tree_guarded = function(_, _, callback)
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
