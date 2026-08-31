local h = require("tests.helpers")
local fs = require("aichatter.fs")

local uv = vim.uv

local function wait_for_callback(start)
  local calls, callback_error = 0
  start(function(err)
    calls = calls + 1
    callback_error = err
  end)
  h.truthy(h.wait_for(function()
    return calls > 0
  end, 2000))
  vim.wait(20)
  h.eq(1, calls)
  return callback_error
end

h.test("copies nested files and excludes .git directories", function()
  local source = h.tempdir()
  local target_parent = h.tempdir()
  local target = target_parent .. "/copy"
  h.mkdir(source .. "/nested")
  h.write(source .. "/nested/a.lua", "return 1\n")
  h.mkdir(source .. "/.git/objects")
  h.write(source .. "/.git/config", "secret")

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, { exclude = { [".git"] = true } }, cb)
  end)

  h.eq(nil, err)
  h.eq("return 1\n", h.read(target .. "/nested/a.lua"))
  h.eq(nil, uv.fs_lstat(target .. "/.git"))
end)

h.test("recreates internal and external symlinks without traversing them", function()
  local source = h.tempdir()
  local outside = h.tempdir()
  local target = h.tempdir() .. "/copy"
  h.mkdir(source .. "/directory")
  h.write(source .. "/directory/a.lua", "inside")
  h.write(outside .. "/external.lua", "outside")
  h.symlink("directory", source .. "/internal-link")
  h.symlink(outside .. "/external.lua", source .. "/external-link")

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, {}, cb)
  end)

  h.eq(nil, err)
  h.eq("link", uv.fs_lstat(target .. "/internal-link").type)
  h.eq("directory", uv.fs_readlink(target .. "/internal-link"))
  h.eq("link", uv.fs_lstat(target .. "/external-link").type)
  h.eq(outside .. "/external.lua", uv.fs_readlink(target .. "/external-link"))
end)

h.test("preserves executable file mode", function()
  local source = h.tempdir()
  local target = h.tempdir() .. "/copy"
  h.write(source .. "/run.sh", "#!/bin/sh\nexit 0\n")
  h.chmod(source .. "/run.sh", 493)

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, {}, cb)
  end)

  h.eq(nil, err)
  h.eq(493, bit.band(uv.fs_stat(target .. "/run.sh").mode, 511))
end)

h.test("reports progress and cancels a copy exactly once", function()
  local source = h.tempdir()
  local target = h.tempdir() .. "/copy"
  for index = 1, 140 do
    h.write(source .. string.format("/file-%03d", index), tostring(index))
  end
  local cancel = { cancelled = false }
  local progress = {}

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, {
      cancel = cancel,
      on_progress = function(count, relative)
        progress[#progress + 1] = { count, relative }
        if relative ~= "" then
          cancel.cancelled = true
        end
      end,
    }, cb)
  end)

  h.eq("cancelled", err.code)
  h.truthy(#progress >= 1)
  for index, item in ipairs(progress) do
    h.eq(index, item[1])
  end
  h.truthy(#progress < 141)
end)

h.test("atomically replaces a file with the requested mode", function()
  local directory = h.tempdir()
  local target = directory .. "/state"
  h.write(target, "old")

  local err = wait_for_callback(function(cb)
    fs.atomic_write(target, "new bytes", 416, cb)
  end)

  h.eq(nil, err)
  h.eq("new bytes", h.read(target))
  h.eq(416, bit.band(uv.fs_stat(target).mode, 511))
  local entries = 0
  for _ in vim.fs.dir(directory) do
    entries = entries + 1
  end
  h.eq(1, entries)
end)

h.test("refuses cleanup outside the recorded temp parent", function()
  local parent = h.tempdir()
  local sibling = parent .. "-old"
  local target = sibling .. "/aichatter-session"
  h.mkdir(target)

  local calls, err = 0
  fs.remove_tree_guarded(target, parent, function(value)
    calls = calls + 1
    err = value
  end)

  h.eq(1, calls)
  h.matches("outside expected parent", err.message)
  h.truthy(uv.fs_lstat(target))
end)

h.test("refuses cleanup of the expected parent itself", function()
  local parent_root = h.tempdir()
  local parent = parent_root .. "/aichatter-parent"
  h.mkdir(parent)

  local err = wait_for_callback(function(cb)
    fs.remove_tree_guarded(parent, parent, cb)
  end)

  h.matches("must be strictly inside expected parent", err.message)
  h.truthy(uv.fs_lstat(parent))
end)

h.test("refuses cleanup without an aichatter basename", function()
  local parent = h.tempdir()
  local target = parent .. "/other-session"
  h.mkdir(target)

  local err = wait_for_callback(function(cb)
    fs.remove_tree_guarded(target, parent, cb)
  end)

  h.matches("basename must begin with aichatter%-", err.message)
  h.truthy(uv.fs_lstat(target))
end)

h.test("removes a guarded tree without following external symlinks", function()
  local parent = h.tempdir()
  local outside = h.tempdir()
  local target = parent .. "/aichatter-session"
  h.mkdir(target .. "/nested")
  h.write(target .. "/nested/file", "inside")
  h.write(outside .. "/keep", "outside")
  h.symlink(outside, target .. "/outside-link")

  local err = wait_for_callback(function(cb)
    fs.remove_tree_guarded(target .. "/.", parent, cb)
  end)

  h.eq(nil, err)
  h.eq(nil, uv.fs_lstat(target))
  h.eq("outside", h.read(outside .. "/keep"))
end)
