local h = require("tests.helpers")

local function call(invoke)
  local err, value, calls
  local callback_calls = 0
  invoke(function(callback_err, callback_value)
    callback_calls = callback_calls + 1
    err, value = callback_err, callback_value
  end)
  assert(h.wait_for(function() return callback_calls > 0 end, 3000), "timed out waiting for review")
  vim.wait(20)
  calls = callback_calls
  h.eq(1, calls)
  return err, value
end

local function action(fixture, method, ...)
  local args = { ... }
  return call(function(callback)
    args[#args + 1] = callback
    fixture.review[method](fixture.review, unpack(args))
  end)
end

local function failing_fs(fail_at)
  local real = require("aichatter.fs")
  local calls = 0
  return setmetatable({
    atomic_write = function(target, bytes, mode, callback)
      calls = calls + 1
      if calls == fail_at then
        vim.schedule(function()
          callback({ code = "injected", message = "injected write failure" })
        end)
        return
      end
      real.atomic_write(target, bytes, mode, callback)
    end,
  }, { __index = real })
end

local function link_review_fixture(base_target, candidate_target, live_target)
  local baseline_root, workspace_root, live_root = h.tempdir(), h.tempdir(), h.tempdir()
  local relative = "link"
  local function replace(root, target)
    local filename = root .. "/" .. relative
    if vim.uv.fs_lstat(filename) then assert(vim.uv.fs_unlink(filename)) end
    if target ~= nil then h.symlink(target, filename) end
  end
  replace(baseline_root, base_target)
  replace(workspace_root, candidate_target)
  replace(live_root, live_target)
  local Review = require("aichatter.review")
  local Live = require("aichatter.live")
  local review = Review.new({
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live = Live.new(live_root),
  })
  h.eq(nil, call(function(callback) review:refresh(callback) end))
  return {
    review = review,
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live_root = live_root,
    readlink = function(root)
      return vim.uv.fs_lstat(root .. "/" .. relative)
        and vim.uv.fs_readlink(root .. "/" .. relative) or nil
    end,
  }
end

h.test("reviews unchanged created modified and deleted internal and external links", function()
  local outside = h.tempdir()
  h.write(outside .. "/old", "outside old\n")
  h.write(outside .. "/new", "outside new\n")
  for label, targets in pairs({
    internal = { old = "old.txt", new = "new.txt" },
    external = { old = outside .. "/old", new = outside .. "/new" },
  }) do
    local unchanged = link_review_fixture(targets.old, targets.old, targets.old)
    h.eq(0, #unchanged.review:files())

    local created = link_review_fixture(nil, targets.new, nil)
    h.eq("link", created.review:files()[1].candidate_kind)
    h.eq(nil, action(created, "accept_file", "link"), label .. " created")
    h.eq(targets.new, created.readlink(created.live_root))
    h.eq(targets.new, created.readlink(created.baseline_root))

    local modified = link_review_fixture(targets.old, targets.new, targets.old)
    h.eq("link", modified.review:files()[1].base_kind)
    h.eq(nil, action(modified, "accept_file", "link"), label .. " modified")
    h.eq(targets.new, modified.readlink(modified.live_root))
    h.eq(targets.new, modified.readlink(modified.baseline_root))

    local deleted = link_review_fixture(targets.old, nil, targets.old)
    h.eq(nil, action(deleted, "accept_file", "link"), label .. " deleted")
    h.eq(nil, deleted.readlink(deleted.live_root))
    h.eq(nil, deleted.readlink(deleted.baseline_root))

    local rejected = link_review_fixture(targets.old, targets.new, targets.old)
    h.eq(nil, action(rejected, "reject_file", "link"), label .. " rejected")
    h.eq(targets.old, rejected.readlink(rejected.workspace_root))
    h.eq(targets.old, rejected.readlink(rejected.live_root))
  end
  h.eq("outside old\n", h.read(outside .. "/old"))
  h.eq("outside new\n", h.read(outside .. "/new"))
end)

h.test("refresh exposes proposals without changing live bytes", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local file = fixture.review:files()[1]

  h.eq("old\n", fixture.live_bytes())
  h.eq("main.txt", file.path)
  h.eq("pending", file.status)
  h.eq("old\n", file.base)
  h.eq("new\n", file.candidate)
  h.eq(1, #file.hunks)
end)

h.test("accepts one hunk and retains only the outstanding hunk", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local first = fixture.review:files()[1].hunks[1]

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", first.id))
  local remaining = fixture.review:files()[1].hunks
  h.eq(1, #remaining)
  h.eq("pending", remaining[1].status)
  h.eq(nil, action(fixture, "reject_hunk", "main.txt", remaining[1].id))

  h.eq("a\nB\nc\nd\n", fixture.live_bytes())
  h.eq("a\nB\nc\nd\n", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("accepting a hunk transactionally advances baseline and leaves only outstanding hunks", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local first = fixture.review:files()[1].hunks[1]

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", first.id))

  h.eq("a\nB\nc\nd\n", fixture.baseline_bytes())
  h.eq("a\nB\nc\nD\n", fixture.workspace_bytes())
  local record = fixture.review:files()[1]
  h.eq("a\nB\nc\nd\n", record.base)
  h.eq(1, #record.hunks)
  h.eq({ "d" }, record.hunks[1].base_lines)
  h.eq({ "D" }, record.hunks[1].candidate_lines)
  h.eq("pending", record.hunks[1].status)
end)

h.test("marks an overlapping live edit as conflict without writing", function()
  local fixture = h.review_fixture("a\nb\n", "a\nB\n")
  fixture.set_live("a\nuser edit\n")

  local err = action(fixture, "accept_hunk", "main.txt", 1)

  h.eq("conflict", err.code)
  h.eq("conflict", fixture.review:files()[1].status)
  h.eq("conflict", fixture.review:files()[1].hunks[1].status)
  h.eq(0, fixture.live_write_count())
  h.eq("a\nuser edit\n", fixture.live_bytes())
end)

h.test("accept preserves and reconciles a non-overlapping live edit", function()
  local base = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
  local fixture = h.review_fixture(base, "1\nTWO\n3\n4\n5\n6\n7\n8\n9\n10\n")
  fixture.set_live("1\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.live_bytes())
  h.eq("1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.baseline_bytes())
  h.eq("1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("sync_live incorporates safe edits and reports overlapping paths", function()
  local safe = h.review_fixture("a\nb\nc\n", "a\nB\nc\n")
  safe.set_live("a\nb\nC\n")
  h.eq(nil, action(safe, "sync_live"))
  h.eq("a\nb\nC\n", safe.baseline_bytes())
  h.eq("a\nB\nC\n", safe.workspace_bytes())

  local conflict = h.review_fixture("a\nb\n", "a\nB\n")
  conflict.set_live("a\nuser\n")
  local err = action(conflict, "sync_live")
  h.eq("conflict", err.code)
  h.eq({ "main.txt" }, err.paths)
  h.eq("a\nb\n", conflict.baseline_bytes())
  h.eq("a\nB\n", conflict.workspace_bytes())
  h.eq("conflict", conflict.review:files()[1].status)
end)

h.test("refresh preserves decisions and ids only for identical hunks", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local first_id = fixture.review:files()[1].hunks[1].id
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", first_id))
  local outstanding_id = fixture.review:files()[1].hunks[1].id

  h.eq(nil, action(fixture, "refresh"))
  h.eq(outstanding_id, fixture.review:files()[1].hunks[1].id)
  h.eq("pending", fixture.review:files()[1].hunks[1].status)

  fixture.set_workspace("a\nBee\nc\nD\n")
  h.eq(nil, action(fixture, "refresh"))
  h.truthy(outstanding_id ~= fixture.review:files()[1].hunks[1].id)
  h.eq("pending", fixture.review:files()[1].hunks[1].status)
end)

h.test("edit_candidate recomputes candidate hunks without touching live", function()
  local fixture = h.review_fixture("a\nb\n", "a\nB\n")
  local old_id = fixture.review:files()[1].hunks[1].id

  h.eq(nil, action(fixture, "edit_candidate", "main.txt", "A\nb\n"))

  h.eq("a\nb\n", fixture.live_bytes())
  h.eq("A\nb\n", fixture.workspace_bytes())
  h.truthy(old_id ~= fixture.review:files()[1].hunks[1].id)
  h.eq({ "a" }, fixture.review:files()[1].hunks[1].base_lines)
  h.eq({ "A" }, fixture.review:files()[1].hunks[1].candidate_lines)
end)

h.test("accept_file and reject_file iterate only pending hunks", function()
  local accepted = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local hunks = accepted.review:files()[1].hunks
  h.eq(nil, action(accepted, "accept_hunk", "main.txt", hunks[1].id))
  accepted.set_live("a\nuser-after-accept\nc\nd\n")
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("a\nuser-after-accept\nc\nD\n", accepted.live_bytes())

  local rejected = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  hunks = rejected.review:files()[1].hunks
  h.eq(nil, action(rejected, "accept_hunk", "main.txt", hunks[1].id))
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq("a\nB\nc\nd\n", rejected.live_bytes())
  h.eq("a\nB\nc\nd\n", rejected.workspace_bytes())
end)

h.test("accepts a created text file hunk including an empty baseline", function()
  local fixture = h.review_fixture(nil, "created\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("created\n", fixture.live_bytes())
  h.eq("created\n", fixture.baseline_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("requires a whole-file action before accepting a text deletion", function()
  local fixture = h.review_fixture("deleted\n", nil)

  local err = action(fixture, "accept_hunk", "main.txt", 1)
  h.eq("file_action_required", err.code)
  h.eq("deleted\n", fixture.live_bytes())
  h.eq(nil, action(fixture, "accept_file", "main.txt"))
  h.eq(nil, fixture.live_bytes())
  h.eq(nil, fixture.baseline_bytes())
end)

h.test("accepts and rejects empty-file creation as a file-level action", function()
  local accepted = h.review_fixture(nil, "")
  h.truthy(accepted.review:files()[1].file_level)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("", accepted.live_bytes())
  h.eq("", accepted.baseline_bytes())

  local rejected = h.review_fixture(nil, "")
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq(nil, rejected.workspace_bytes())
  h.eq(nil, rejected.live_bytes())
end)

h.test("accepts and rejects binary files at file level", function()
  local accepted = h.review_fixture("old\0bytes", "new\0bytes")
  local file = accepted.review:files()[1]
  h.truthy(file.binary)
  h.eq(0, #file.hunks)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("new\0bytes", accepted.live_bytes())
  h.eq("new\0bytes", accepted.baseline_bytes())

  local rejected = h.review_fixture("old\0bytes", "new\0bytes")
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq("old\0bytes", rejected.workspace_bytes())
  h.eq("old\0bytes", rejected.live_bytes())
end)

h.test("mode-only changes use file-level accept and reject", function()
  local accepted = h.review_fixture("same\n", "same\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  local file = accepted.review:files()[1]
  h.truthy(file.mode_only)
  h.truthy(file.file_level)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq(493, h.mode(accepted.live_root .. "/main.txt"))
  h.eq(493, h.mode(accepted.baseline_root .. "/main.txt"))

  local rejected = h.review_fixture("same\n", "same\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq(420, h.mode(rejected.workspace_root .. "/main.txt"))
  h.eq(420, h.mode(rejected.live_root .. "/main.txt"))
end)

h.test("accepts a final-newline-only proposal", function()
  local fixture = h.review_fixture("line", "line\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("line\n", fixture.live_bytes())
end)

h.test("accepting into a loaded unsaved buffer leaves disk untouched", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/main.txt", { "old" }, true)
  vim.bo[bufnr].endofline = true

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq({ "new" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].modified)
  h.eq("old\n", h.read(fixture.live_root .. "/main.txt"))
  h.eq("new\n", fixture.live_bytes())
end)

h.test("accounts for an earlier accepted insertion when applying a later hunk", function()
  local fixture = h.review_fixture(
    "a\nb\nc\nd\n",
    "inserted\na\nb\nc\nD\n"
  )
  local hunks = fixture.review:files()[1].hunks
  h.eq(2, #hunks)

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", hunks[1].id))
  local remaining = fixture.review:files()[1].hunks[1]
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", remaining.id))

  h.eq("inserted\na\nb\nc\nD\n", fixture.live_bytes())
end)

h.test("accept_file applies a pending mode change after text hunks", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })

  h.eq(nil, action(fixture, "accept_file", "main.txt"))

  h.eq("new\n", fixture.live_bytes())
  h.eq(493, h.mode(fixture.live_root .. "/main.txt"))
  h.eq(493, h.mode(fixture.baseline_root .. "/main.txt"))
end)

h.test("reject_file rejects a pending mode change after text hunks", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })

  h.eq(nil, action(fixture, "reject_file", "main.txt"))

  h.eq("old\n", fixture.workspace_bytes())
  h.eq(420, h.mode(fixture.workspace_root .. "/main.txt"))
  h.eq("old\n", fixture.live_bytes())
end)

h.test("sync_live conflicts when live and candidate both change mode", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  h.chmod(fixture.live_root .. "/main.txt", 448)

  local err = action(fixture, "sync_live")

  h.eq("conflict", err.code)
  h.eq({ "main.txt" }, err.paths)
  h.eq(420, h.mode(fixture.baseline_root .. "/main.txt"))
  h.eq(493, h.mode(fixture.workspace_root .. "/main.txt"))
end)

h.test("reconciles a live final-newline edit around an accepted insertion", function()
  local fixture = h.review_fixture("a\nb\n", "inserted\na\nb\n")
  fixture.set_live("a\nb")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("inserted\na\nb", fixture.live_bytes())
  h.eq("inserted\na\nb", fixture.baseline_bytes())
  h.eq("inserted\na\nb", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("accept_hunk immediately advances an accepted proposal out of review", function()
  local fixture = h.review_fixture("old\n", "new\n")
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("new\n", fixture.baseline_bytes())
  h.eq("new\n", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("sync_live copies an unsaved loaded edit for a non-proposal file", function()
  local fixture = h.review_fixture("old\n", "new\n")
  h.write(fixture.baseline_root .. "/other.txt", "disk\n")
  h.write(fixture.workspace_root .. "/other.txt", "disk\n")
  h.write(fixture.live_root .. "/other.txt", "disk\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/other.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = true
  h.eq(nil, action(fixture, "refresh"))

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("unsaved\n", h.read(fixture.baseline_root .. "/other.txt"))
  h.eq("unsaved\n", h.read(fixture.workspace_root .. "/other.txt"))
  h.eq("disk\n", h.read(fixture.live_root .. "/other.txt"))
end)

h.test("sync_live leaves an untouched pending binary proposal reviewable", function()
  local fixture = h.review_fixture("old\0bytes", "new\0bytes")

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("old\0bytes", fixture.baseline_bytes())
  h.eq("new\0bytes", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].status)
end)

h.test("sync_live discovers a new file that exists only in a loaded buffer", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/new-buffer.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = true

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("unsaved\n", h.read(fixture.baseline_root .. "/new-buffer.txt"))
  h.eq("unsaved\n", h.read(fixture.workspace_root .. "/new-buffer.txt"))
  h.eq(nil, h.read_optional(fixture.live_root .. "/new-buffer.txt"))
end)

h.test("accept rejects a disk edit made after conflict validation", function()
  local fixture = h.review_fixture("old\n", "candidate\n")
  local calls, captured = 0

  fixture.review:accept_hunk("main.txt", 1, function(err)
    calls, captured = calls + 1, err
  end)
  fixture.set_live("user\n")
  assert(h.wait_for(function() return calls > 0 end, 3000))

  h.eq(1, calls)
  h.truthy(captured)
  h.eq("conflict", captured.code)
  h.eq("user\n", fixture.live_bytes())
  h.eq("old\n", fixture.baseline_bytes())
  h.eq("candidate\n", fixture.workspace_bytes())
end)

h.test("file deletion rejects a disk edit made after validation", function()
  local fixture = h.review_fixture("old\n", nil)
  local calls, captured = 0

  fixture.review:accept_file("main.txt", function(err)
    calls, captured = calls + 1, err
  end)
  fixture.set_live("user\n")
  assert(h.wait_for(function() return calls > 0 end, 3000))

  h.eq(1, calls)
  h.truthy(captured)
  h.eq("conflict", captured.code)
  h.eq("user\n", fixture.live_bytes())
  h.eq("old\n", fixture.baseline_bytes())
end)

h.test("sync applies adjacent user deletion after an accepted insertion once", function()
  local fixture = h.review_fixture("a\nb\n", "inserted\na\nb\n")
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))
  fixture.set_live("inserted\nb\n")

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("inserted\nb\n", fixture.baseline_bytes())
  h.eq("inserted\nb\n", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("later accept reconciles a deletion adjacent to an accepted insertion once", function()
  local fixture = h.review_fixture(
    "a\nb\nc\nd\n",
    "inserted\na\nb\nc\nD\n"
  )
  local hunks = fixture.review:files()[1].hunks
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", hunks[1].id))
  fixture.set_live("inserted\nb\nc\nd\n")

  local remaining = fixture.review:files()[1].hunks[1]
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", remaining.id))

  h.eq("inserted\nb\nc\nD\n", fixture.live_bytes())
  h.eq("inserted\nb\nc\nD\n", fixture.baseline_bytes())
  h.eq("inserted\nb\nc\nD\n", fixture.workspace_bytes())
end)

h.test("reconcile failure rolls back live baseline workspace and decision", function()
  local fs = failing_fs(2)
  local fixture = h.review_fixture("a\nb\nc\n", "a\nB\nc\n", {
    review_dependencies = { fs = fs },
  })
  fixture.set_live("a\nb\nC\n")

  local err = action(fixture, "accept_hunk", "main.txt", 1)

  h.eq("injected", err.code)
  h.eq("a\nb\nC\n", fixture.live_bytes())
  h.eq("a\nb\nc\n", fixture.baseline_bytes())
  h.eq("a\nB\nc\n", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].hunks[1].status)
end)

h.test("reconcile rollback restores exact unmodified loaded-buffer state", function()
  local fs = failing_fs(2)
  local fixture = h.review_fixture("a\nb\nc\n", "a\nB\nc\n", {
    review_dependencies = { fs = fs },
  })
  local filename = fixture.live_root .. "/main.txt"
  local bufnr = h.load_buffer(filename, { "a", "b", "C" }, false)
  vim.bo[bufnr].endofline = false
  vim.bo[bufnr].modified = false

  local err = action(fixture, "accept_hunk", "main.txt", 1)

  h.eq("injected", err.code)
  h.truthy(vim.api.nvim_buf_is_valid(bufnr))
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq(filename, vim.api.nvim_buf_get_name(bufnr))
  h.eq({ "a", "b", "C" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.falsy(vim.bo[bufnr].endofline)
  h.falsy(vim.bo[bufnr].modified)
  h.eq("a\nb\nc\n", h.read(filename))
  h.eq("a\nb\nc\n", fixture.baseline_bytes())
  h.eq("a\nB\nc\n", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].hunks[1].status)
end)

h.test("whole-file baseline failure rolls back accepted binary live bytes", function()
  local fs = failing_fs(1)
  local fixture = h.review_fixture("old\0bytes", "new\0bytes", {
    review_dependencies = { fs = fs },
  })

  local err = action(fixture, "accept_file", "main.txt")

  h.eq("injected", err.code)
  h.eq("old\0bytes", fixture.live_bytes())
  h.eq("old\0bytes", fixture.baseline_bytes())
  h.eq("new\0bytes", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].status)
end)

h.test("deletion preflight failure preserves the exact loaded buffer", function()
  local real_uv = vim.uv
  local fail_target
  local failed = false
  local uv = setmetatable({
    fs_unlink = function(target)
      if target == fail_target and not failed then
        failed = true
        return nil, "injected unlink failure", "EUNLINK"
      end
      return real_uv.fs_unlink(target)
    end,
  }, { __index = real_uv })
  local fixture = h.review_fixture("old\n", nil, {
    review_dependencies = { uv = uv },
  })
  local filename = fixture.live_root .. "/main.txt"
  fail_target = fixture.baseline_root .. "/main.txt"
  local bufnr = h.load_buffer(filename, { "old" }, false)
  vim.bo[bufnr].endofline = true
  vim.bo[bufnr].modified = false

  local err = action(fixture, "accept_file", "main.txt")

  h.eq("EUNLINK", err.code)
  h.truthy(vim.api.nvim_buf_is_valid(bufnr))
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq(filename, vim.api.nvim_buf_get_name(bufnr))
  h.eq({ "old" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].endofline)
  h.falsy(vim.bo[bufnr].modified)
  h.eq("old\n", h.read(filename))
  h.eq("old\n", fixture.baseline_bytes())
  h.eq(nil, fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].status)
end)

h.test("sync workspace failure rolls back the baseline snapshot", function()
  local fs = failing_fs(2)
  local fixture = h.review_fixture("a\nb\nc\n", "a\nB\nc\n", {
    review_dependencies = { fs = fs },
  })
  fixture.set_live("a\nb\nC\n")

  local err = action(fixture, "sync_live")

  h.eq("injected", err.code)
  h.eq("a\nb\nc\n", fixture.baseline_bytes())
  h.eq("a\nB\nc\n", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].status)
end)

h.test("refresh rejects bytes changed after their manifest snapshot", function()
  local baseline_root, workspace_root, live_root = h.tempdir(), h.tempdir(), h.tempdir()
  h.write(baseline_root .. "/main.txt", "old\n")
  h.write(workspace_root .. "/main.txt", "new\n")
  h.write(live_root .. "/main.txt", "old\n")
  local real_manifest = require("aichatter.manifest")
  local raced = false
  local manifest = setmetatable({
    scan = function(root, opts, callback)
      real_manifest.scan(root, opts, function(err, entries)
        if not err and root == baseline_root and not raced then
          raced = true
          h.write(baseline_root .. "/main.txt", "raced\n")
        end
        callback(err, entries)
      end)
    end,
  }, { __index = real_manifest })
  local Review = require("aichatter.review")._new({ manifest = manifest })
  local review = Review.new({
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live = require("aichatter.live").new(live_root),
  })

  local err = call(function(callback) review:refresh(callback) end)

  h.truthy(err)
  h.eq("changed", err.code)
  h.eq({}, review:files())
end)

h.test("refresh propagates a snapshot read failure", function()
  local baseline_root, workspace_root, live_root = h.tempdir(), h.tempdir(), h.tempdir()
  h.write(baseline_root .. "/main.txt", "old\n")
  h.write(workspace_root .. "/main.txt", "new\n")
  h.write(live_root .. "/main.txt", "old\n")
  local real_uv = vim.uv
  local uv = setmetatable({
    fs_open = function(target, ...)
      if target == baseline_root .. "/main.txt" then
        return nil, "injected read failure", "EREAD"
      end
      return real_uv.fs_open(target, ...)
    end,
  }, { __index = real_uv })
  local Review = require("aichatter.review")._new({ uv = uv })
  local review = Review.new({
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live = require("aichatter.live").new(live_root),
  })

  local err = call(function(callback) review:refresh(callback) end)

  h.truthy(err)
  h.eq("EREAD", err.code)
  h.eq({}, review:files())
end)

h.test("sync_live incorporates binary bytes after the text proposal is accepted", function()
  local fixture = h.review_fixture("old\n", "new\n")
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))
  fixture.set_live("binary\0bytes")

  local err = action(fixture, "sync_live")

  h.eq(nil, err)
  h.eq("binary\0bytes", fixture.baseline_bytes())
  h.eq("binary\0bytes", fixture.workspace_bytes())
end)

h.test("a reverted overlap can be revalidated and accepted", function()
  local fixture = h.review_fixture("old\n", "new\n")
  fixture.set_live("user\n")
  h.eq("conflict", action(fixture, "accept_hunk", "main.txt", 1).code)
  fixture.set_live("old\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("new\n", fixture.live_bytes())
  h.eq("new\n", fixture.baseline_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("sync clears a derived conflict after the live overlap is reverted", function()
  local fixture = h.review_fixture("old\n", "new\n")
  fixture.set_live("user\n")
  h.eq("conflict", action(fixture, "accept_hunk", "main.txt", 1).code)
  fixture.set_live("old\n")

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("pending", fixture.review:files()[1].status)
  h.eq("pending", fixture.review:files()[1].hunks[1].status)
end)

h.test("requires callbacks for every asynchronous review API", function()
  local fixture = h.review_fixture("old\n", "new\n")

  h.raises("callback", function() fixture.review:refresh() end)
  h.raises("callback", function() fixture.review:sync_live() end)
  h.raises("callback", function() fixture.review:accept_hunk("main.txt", 1) end)
  h.raises("callback", function() fixture.review:reject_hunk("main.txt", 1) end)
  h.raises("callback", function() fixture.review:edit_candidate("main.txt", "edit\n") end)
  h.raises("callback", function() fixture.review:accept_file("main.txt") end)
  h.raises("callback", function() fixture.review:reject_file("main.txt") end)
end)
