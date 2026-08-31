local h = require("tests.helpers")
local Live = require("aichatter.live")

local function wait_call(invoke)
  local err, calls = h.await(invoke)
  h.eq(1, calls)
  return err
end

local function disk_snapshot(path)
  local stat = assert(vim.uv.fs_lstat(path))
  return {
    exists = true,
    bytes = h.read(path),
    mode = bit.band(stat.mode, 511),
    identity = { dev = stat.dev, ino = stat.ino },
  }
end

h.test("reads loaded unsaved buffer bytes before disk bytes", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "unsaved" }, true)
  vim.bo[bufnr].endofline = false

  h.eq("unsaved", Live.new(root):read("./main.lua"))
end)

h.test("reads a loaded zero-byte buffer as exact empty bytes", function()
  local root = h.tempdir()
  h.write(root .. "/empty.txt", "")
  local bufnr = vim.fn.bufadd(root .. "/empty.txt")
  vim.fn.bufload(bufnr)
  h.eq({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].endofline)

  h.eq("", Live.new(root):read("empty.txt"))
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("updates a loaded unsaved buffer without writing disk", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "unsaved" }, true)
  local live = Live.new(root)
  local calls = 0

  live:write("main.lua", "accepted", 420, function(err)
    calls = calls + 1
    h.assert_no_error(err)
  end)

  h.eq(1, calls)
  h.eq({ "accepted" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.falsy(vim.bo[bufnr].endofline)
  h.truthy(vim.bo[bufnr].modified)
  h.eq("disk\n", h.read(root .. "/main.lua"))
end)

h.test("atomically writes an unloaded path with the requested mode", function()
  local root = h.tempdir()
  local live = Live.new(root)

  local err = wait_call(function(callback)
    live:write("nested/main.lua", "accepted\n", 493, callback)
  end)

  h.eq(nil, err)
  h.eq("accepted\n", h.read(root .. "/nested/main.lua"))
  h.eq(493, h.mode(root .. "/nested/main.lua"))
end)

h.test("snapshots and atomically replaces symlinks without following targets", function()
  local root = h.tempdir()
  local outside = h.tempdir()
  h.write(outside .. "/first", "first\n")
  h.write(outside .. "/second", "second\n")
  h.symlink(outside .. "/first", root .. "/link")
  local live = Live.new(root)
  local before = assert(live:snapshot("link"))

  h.eq("link", before.kind)
  h.eq(outside .. "/first", before.target)
  local err = wait_call(function(callback)
    live:write_link("link", outside .. "/second", before, callback)
  end)

  h.eq(nil, err)
  h.eq("link", vim.uv.fs_lstat(root .. "/link").type)
  h.eq(outside .. "/second", vim.uv.fs_readlink(root .. "/link"))
  h.eq("first\n", h.read(outside .. "/first"))
  h.eq("second\n", h.read(outside .. "/second"))
end)

h.test("creates and deletes symlinks with guarded typed snapshots", function()
  local root = h.tempdir()
  local live = Live.new(root)
  local missing = assert(live:snapshot("created-link"))

  local create_err = wait_call(function(callback)
    live:write_link("created-link", "inside.txt", missing, callback)
  end)
  h.eq(nil, create_err)
  local created = assert(live:snapshot("created-link"))
  h.eq("link", created.kind)
  h.eq("inside.txt", created.target)

  local delete_err = wait_call(function(callback)
    live:delete("created-link", created, callback)
  end)
  h.eq(nil, delete_err)
  h.eq(nil, vim.uv.fs_lstat(root .. "/created-link"))
end)

h.test("refuses normalized paths outside the live root", function()
  local parent = h.tempdir()
  local root = parent .. "/project"
  h.mkdir(root)
  h.write(parent .. "/outside", "safe\n")
  local live = Live.new(root)

  local bytes, read_err = live:read("../outside")
  h.eq(nil, bytes)
  h.eq("outside_root", read_err.code)
  local write_err = wait_call(function(callback)
    live:write("sub/../../outside", "changed\n", 420, callback)
  end)
  local delete_err = wait_call(function(callback)
    live:delete("../outside", callback)
  end)

  h.eq("outside_root", write_err.code)
  h.eq("outside_root", delete_err.code)
  h.eq("safe\n", h.read(parent .. "/outside"))
end)

h.test("refuses to delete a modified loaded buffer", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "unsaved" }, true)
  local live = Live.new(root)

  local err = wait_call(function(callback)
    live:delete("main.lua", callback)
  end)

  h.eq("modified_buffer", err.code)
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq({ "unsaved" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.eq("disk\n", h.read(root .. "/main.lua"))
end)

h.test("deletes an unmodified loaded file without saving the buffer", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "disk" }, false)
  local live = Live.new(root)

  local err = wait_call(function(callback)
    live:delete("main.lua", callback)
  end)

  h.eq(nil, err)
  h.falsy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq(nil, h.read_optional(root .. "/main.lua"))
end)

h.test("deleting a missing unloaded file succeeds exactly once", function()
  local live = Live.new(h.tempdir())
  local err = wait_call(function(callback)
    live:delete("missing", callback)
  end)
  h.eq(nil, err)
end)

h.test("applies an accepted mode change for a loaded file without saving content", function()
  local root = h.tempdir()
  h.write(root .. "/script", "disk\n")
  h.chmod(root .. "/script", 420)
  local bufnr = h.load_buffer(root .. "/script", { "accepted" }, true)
  vim.bo[bufnr].endofline = true
  local live = Live.new(root)

  local calls = 0
  live:write("script", "accepted\n", 493, function(err)
    calls = calls + 1
    h.eq(nil, err)
  end)

  h.eq(1, calls)
  h.eq(493, h.mode(root .. "/script"))
  h.eq("disk\n", h.read(root .. "/script"))
  h.eq("accepted\n", live:read("script"))
end)

h.test("guarded unloaded write rejects a file changed after validation", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local live = Live.new(root)
  local expected = disk_snapshot(root .. "/main.txt")
  local calls, captured = 0

  live:write("main.txt", "candidate\n", 420, expected, function(err)
    calls, captured = calls + 1, err
  end)
  h.write(root .. "/main.txt", "user\n")
  assert(h.wait_for(function() return calls > 0 end, 3000))

  h.eq(1, calls)
  h.eq("conflict", captured.code)
  h.eq("user\n", h.read(root .. "/main.txt"))
end)

h.test("queued write conflicts when its unloaded path becomes loaded", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local queued = {}
  local schedule = function(fn) queued[#queued + 1] = fn end
  local fs = require("aichatter.fs")._new({ schedule = schedule })
  local InjectedLive = Live._new({ fs = fs, schedule = schedule })
  local live = InjectedLive.new(root)
  local expected = assert(live:snapshot("main.txt"))
  local calls, captured = 0

  live:write("main.txt", "candidate\n", 420, expected, function(err)
    calls, captured = calls + 1, err
  end)
  local bufnr = h.load_buffer(root .. "/main.txt", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  h.eq(1, #queued)
  queued[1]()

  h.eq(1, calls)
  h.eq("conflict", captured.code)
  h.eq("baseline\n", h.read(root .. "/main.txt"))
  h.eq("baseline\n", live:read("main.txt"))
end)

h.test("guarded delete rejects a file changed after validation", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local live = Live.new(root)
  local expected = disk_snapshot(root .. "/main.txt")
  local calls, captured = 0

  live:delete("main.txt", expected, function(err)
    calls, captured = calls + 1, err
  end)
  h.write(root .. "/main.txt", "user\n")
  assert(h.wait_for(function() return calls > 0 end, 3000))

  h.eq(1, calls)
  h.eq("conflict", captured.code)
  h.eq("user\n", h.read(root .. "/main.txt"))
end)

h.test("queued delete conflicts when its unloaded path becomes loaded", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local queued = {}
  local schedule = function(fn) queued[#queued + 1] = fn end
  local InjectedLive = Live._new({ schedule = schedule })
  local live = InjectedLive.new(root)
  local expected = assert(live:snapshot("main.txt"))
  local calls, captured = 0

  live:delete("main.txt", expected, function(err)
    calls, captured = calls + 1, err
  end)
  local bufnr = h.load_buffer(root .. "/main.txt", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  h.eq(1, #queued)
  queued[1]()

  h.eq(1, calls)
  h.eq("conflict", captured.code)
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq("baseline\n", h.read(root .. "/main.txt"))
end)

h.test("guarded loaded delete preserves a disk edit behind the buffer", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local bufnr = h.load_buffer(root .. "/main.txt", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  local live = Live.new(root)
  local expected = assert(live:snapshot("main.txt"))
  local calls, captured = 0

  live:delete("main.txt", expected, function(err)
    calls, captured = calls + 1, err
  end)
  h.write(root .. "/main.txt", "user\n")
  assert(h.wait_for(function() return calls > 0 end, 3000))

  h.eq(1, calls)
  h.eq("conflict", captured.code)
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq("user\n", h.read(root .. "/main.txt"))
end)

h.test("guarded loaded write rejects a changed buffer tick", function()
  local root = h.tempdir()
  h.write(root .. "/main.txt", "baseline\n")
  local bufnr = h.load_buffer(root .. "/main.txt", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  local live = Live.new(root)
  local expected = disk_snapshot(root .. "/main.txt")
  expected.bufnr = bufnr
  expected.changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "user" })

  local captured
  live:write("main.txt", "candidate\n", 420, expected, function(err)
    captured = err
  end)

  h.truthy(captured)
  h.eq("conflict", captured.code)
  h.eq("user\n", live:read("main.txt"))
  h.eq("baseline\n", h.read(root .. "/main.txt"))
end)

h.test("rejects symlink ancestors without touching outside bytes or mode", function()
  local root, outside = h.tempdir(), h.tempdir()
  h.write(outside .. "/file", "outside\n")
  h.chmod(outside .. "/file", 420)
  h.symlink(outside, root .. "/linked")
  local live = Live.new(root)

  local bytes, read_err = live:read("linked/file")
  local mode, mode_err = live:mode("linked/file")
  local write_err = wait_call(function(callback)
    live:write("linked/file", "changed\n", 493, callback)
  end)
  local delete_err = wait_call(function(callback)
    live:delete("linked/file", callback)
  end)

  h.eq(nil, bytes)
  h.eq("symlink_ancestor", read_err.code)
  h.eq(nil, mode)
  h.eq("symlink_ancestor", mode_err.code)
  h.eq("symlink_ancestor", write_err.code)
  h.eq("symlink_ancestor", delete_err.code)
  h.eq("outside\n", h.read(outside .. "/file"))
  h.eq(420, h.mode(outside .. "/file"))
end)

h.test("rejects a root replaced by a symlink after construction", function()
  local parent, outside = h.tempdir(), h.tempdir()
  local root = parent .. "/project"
  h.mkdir(root)
  h.write(root .. "/file", "inside\n")
  h.write(outside .. "/file", "outside\n")
  local live = Live.new(root)
  assert(vim.uv.fs_rename(root, parent .. "/old-project"))
  h.symlink(outside, root)

  local bytes, err = live:read("file")

  h.eq(nil, bytes)
  h.eq("root_changed", err.code)
  h.eq("outside\n", h.read(outside .. "/file"))
end)

h.test("scheduled write rejects an ancestor changed into a symlink", function()
  local root, outside = h.tempdir(), h.tempdir()
  h.mkdir(root .. "/nested")
  h.write(root .. "/nested/file", "inside\n")
  h.write(outside .. "/file", "outside\n")
  local queued = {}
  local schedule = function(fn) queued[#queued + 1] = fn end
  local fs = require("aichatter.fs")._new({ schedule = schedule })
  local InjectedLive = Live._new({ fs = fs, schedule = schedule })
  local live = InjectedLive.new(root)
  local expected = assert(live:snapshot("nested/file"))
  local calls, captured = 0

  live:write("nested/file", "candidate\n", 420, expected, function(err)
    calls, captured = calls + 1, err
  end)
  assert(vim.uv.fs_rename(root .. "/nested", root .. "/old-nested"))
  h.symlink(outside, root .. "/nested")
  h.eq(1, #queued)
  queued[1]()

  h.eq(1, calls)
  h.truthy(captured)
  h.eq("outside\n", h.read(outside .. "/file"))
  h.eq("inside\n", h.read(root .. "/old-nested/file"))
end)

h.test("reads a loaded buffer named through a symlinked root alias", function()
  local parent = h.tempdir()
  local actual, alias = parent .. "/actual", parent .. "/alias"
  h.mkdir(actual)
  h.write(actual .. "/main.txt", "disk\n")
  h.symlink(actual, alias)
  local bufnr = h.load_buffer(alias .. "/main.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = false

  local live = Live.new(alias)

  h.eq("unsaved", live:read("main.txt"))
  h.eq("disk\n", h.read(actual .. "/main.txt"))
end)

h.test("writes a loaded buffer named through a symlinked root alias", function()
  local parent = h.tempdir()
  local actual, alias = parent .. "/actual", parent .. "/alias"
  h.mkdir(actual)
  h.write(actual .. "/main.txt", "disk\n")
  h.symlink(actual, alias)
  local bufnr = h.load_buffer(alias .. "/main.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = false
  local live = Live.new(alias)
  local calls, captured = 0

  live:write("main.txt", "accepted\n", 420, function(err)
    calls, captured = calls + 1, err
  end)

  h.eq(1, calls)
  h.eq(nil, captured)
  h.eq({ "accepted" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].endofline)
  h.eq("disk\n", h.read(actual .. "/main.txt"))
end)

h.test("refuses to delete an unsaved buffer named through a root alias", function()
  local parent = h.tempdir()
  local actual, alias = parent .. "/actual", parent .. "/alias"
  h.mkdir(actual)
  h.write(actual .. "/main.txt", "disk\n")
  h.symlink(actual, alias)
  local bufnr = h.load_buffer(alias .. "/main.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = false
  local live = Live.new(alias)

  local err = wait_call(function(callback) live:delete("main.txt", callback) end)

  h.eq("modified_buffer", err.code)
  h.truthy(vim.api.nvim_buf_is_loaded(bufnr))
  h.eq({ "unsaved" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.eq("disk\n", h.read(actual .. "/main.txt"))
end)

h.test("rejects a root alias retargeted after construction", function()
  local parent = h.tempdir()
  local actual, outside, alias = parent .. "/actual", parent .. "/outside", parent .. "/alias"
  h.mkdir(actual)
  h.mkdir(outside)
  h.write(actual .. "/main.txt", "inside\n")
  h.write(outside .. "/main.txt", "outside\n")
  h.symlink(actual, alias)
  local live = Live.new(alias)
  assert(vim.uv.fs_unlink(alias))
  h.symlink(outside, alias)

  local bytes, err = live:read("main.txt")

  h.eq(nil, bytes)
  h.eq("root_changed", err.code)
  h.eq("inside\n", h.read(actual .. "/main.txt"))
  h.eq("outside\n", h.read(outside .. "/main.txt"))
end)

h.test("loaded write rolls back mode when the buffer cannot change", function()
  local root = h.tempdir()
  h.write(root .. "/script", "baseline\n")
  h.chmod(root .. "/script", 420)
  local bufnr = h.load_buffer(root .. "/script", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  vim.bo[bufnr].modifiable = false
  local live = Live.new(root)
  local captured

  live:write("script", "candidate\n", 493, function(err) captured = err end)

  h.truthy(captured)
  h.eq(420, h.mode(root .. "/script"))
  h.eq("baseline\n", live:read("script"))
end)

h.test("loaded write rolls back mode after a later descriptor failure", function()
  local root = h.tempdir()
  h.write(root .. "/script", "baseline\n")
  h.chmod(root .. "/script", 420)
  local bufnr = h.load_buffer(root .. "/script", { "baseline" }, false)
  vim.bo[bufnr].endofline = true
  local real_uv = vim.uv
  local closes = 0
  local uv = setmetatable({
    fs_close = function(fd)
      closes = closes + 1
      local closed, err, code = real_uv.fs_close(fd)
      if closes == 3 then return nil, "injected close failure", "ECLOSE" end
      return closed, err, code
    end,
  }, { __index = real_uv })
  local InjectedLive = Live._new({ uv = uv })
  local live = InjectedLive.new(root)
  local captured

  live:write("script", "candidate\n", 493, function(err) captured = err end)

  h.truthy(captured)
  h.eq("ECLOSE", captured.code)
  h.eq(420, h.mode(root .. "/script"))
  h.eq("baseline\n", live:read("script"))
end)

h.test("requires callbacks for asynchronous live filesystem branches", function()
  local root = h.tempdir()
  h.write(root .. "/file", "bytes\n")
  local live = Live.new(root)

  h.raises("callback", function() live:write("file", "new\n", 420) end)
  h.raises("callback", function() live:delete("file") end)

  local bufnr = h.load_buffer(root .. "/file", { "bytes" }, true)
  vim.bo[bufnr].endofline = true
  live:write("file", "buffer\n", 420)
  h.eq("buffer\n", live:read("file"))
end)
