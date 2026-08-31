local h = require("tests.helpers")
local Live = require("aichatter.live")

local function wait_call(invoke)
  local err, calls = h.await(invoke)
  h.eq(1, calls)
  return err
end

h.test("reads loaded unsaved buffer bytes before disk bytes", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "unsaved" }, true)
  vim.bo[bufnr].endofline = false

  h.eq("unsaved", Live.new(root):read("./main.lua"))
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
