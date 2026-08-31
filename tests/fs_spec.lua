local h = require("tests.helpers")
local fs = require("aichatter.fs")

local uv = vim.uv

local function uv_with(overrides)
  return setmetatable(overrides or {}, { __index = uv })
end

local function directory_entries(directory)
  local entries = {}
  for name in vim.fs.dir(directory) do
    entries[#entries + 1] = name
  end
  table.sort(entries)
  return entries
end

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

h.test("creates a missing destination parent hierarchy", function()
  local source = h.tempdir()
  local target_root = h.tempdir()
  local target = target_root .. "/missing/parents/copy"
  h.write(source .. "/a.lua", "return 1\n")

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, {}, cb)
  end)

  h.eq(nil, err)
  h.eq("return 1\n", h.read(target .. "/a.lua"))
end)

h.test("refuses to create destination parents through a symlink", function()
  local source = h.tempdir()
  local target_root = h.tempdir()
  local outside = h.tempdir()
  local linked = target_root .. "/linked"
  h.write(source .. "/a.lua", "return 1\n")
  h.symlink(outside, linked)

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, linked .. "/missing/copy", {}, cb)
  end)

  h.matches("symlink ancestor", err.message)
  h.eq(nil, uv.fs_lstat(outside .. "/missing"))
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

h.test("safely overlays an existing tree with exact relative exclusions", function()
  local source = h.tempdir()
  local target = h.tempdir() .. "/copy"
  local outside = h.tempdir()
  h.mkdir(source .. "/nested")
  h.write(source .. "/nested/keep.txt", "new\n")
  h.write(source .. "/nested/proposed.txt", "live proposal\n")
  h.write(source .. "/replace-link", "safe replacement\n")
  h.symlink("nested/keep.txt", source .. "/new-link")
  h.mkdir(target .. "/nested")
  h.write(target .. "/nested/keep.txt", "old\n")
  h.write(target .. "/nested/proposed.txt", "shadow proposal\n")
  h.write(target .. "/new-link", "old regular file\n")
  h.write(outside .. "/untouched", "outside\n")
  h.symlink(outside .. "/untouched", target .. "/replace-link")

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, {
      overlay = true,
      exclude = { ["nested/proposed.txt"] = true },
    }, cb)
  end)

  h.eq(nil, err)
  h.eq("new\n", h.read(target .. "/nested/keep.txt"))
  h.eq("shadow proposal\n", h.read(target .. "/nested/proposed.txt"))
  h.eq("safe replacement\n", h.read(target .. "/replace-link"))
  h.eq("outside\n", h.read(outside .. "/untouched"))
  h.eq("link", uv.fs_lstat(target .. "/new-link").type)
  h.eq("nested/keep.txt", uv.fs_readlink(target .. "/new-link"))
end)

h.test("overlay replaces a hardlinked destination without mutating its peer", function()
  local source = h.tempdir()
  local target = h.tempdir() .. "/copy"
  local protected = h.tempdir() .. "/protected.txt"
  h.write(source .. "/state.txt", "fresh\n")
  h.write(protected, "protected\n")
  h.mkdir(target)
  assert(uv.fs_link(protected, target .. "/state.txt"))
  local protected_inode = uv.fs_stat(protected).ino
  h.eq(protected_inode, uv.fs_stat(target .. "/state.txt").ino)

  local err = wait_for_callback(function(cb)
    fs.copy_tree(source, target, { overlay = true }, cb)
  end)

  h.eq(nil, err)
  h.eq("fresh\n", h.read(target .. "/state.txt"))
  h.eq("protected\n", h.read(protected))
  h.eq(protected_inode, uv.fs_stat(protected).ino)
  h.falsy(protected_inode == uv.fs_stat(target .. "/state.txt").ino)
end)

h.test("yields at the batch boundary and cancels with an exact partial tree", function()
  local source = h.tempdir()
  local target = h.tempdir() .. "/copy"
  for index = 1, 140 do
    h.write(source .. string.format("/file-%03d", index), tostring(index))
  end
  local cancel = { cancelled = false }
  local scheduled = {}
  local isolated = fs._new({
    schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end,
  })
  local calls, callback_error = 0

  isolated.copy_tree(source, target, { cancel = cancel }, function(err)
    calls = calls + 1
    callback_error = err
  end)

  h.eq(1, #scheduled)
  table.remove(scheduled, 1)()
  h.eq(0, calls)
  h.eq(1, #scheduled)
  cancel.cancelled = true
  table.remove(scheduled, 1)()

  h.eq(1, calls)
  h.eq("cancelled", callback_error.code)
  h.eq(127, #directory_entries(target))
  h.truthy(uv.fs_lstat(target .. "/file-001"))
  h.truthy(uv.fs_lstat(target .. "/file-127"))
  h.eq(nil, uv.fs_lstat(target .. "/file-128"))
  h.eq(nil, uv.fs_lstat(target .. "/file-140"))
end)

h.test("atomically replaces a file with the requested mode", function()
  local directory = h.tempdir()
  local target = directory .. "/state"
  h.write(target, "old")
  local events = {}
  local isolated = fs._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      fs_write = function(...)
        events[#events + 1] = "write"
        return uv.fs_write(...)
      end,
      fs_fsync = function(...)
        events[#events + 1] = "fsync"
        return uv.fs_fsync(...)
      end,
      fs_close = function(...)
        events[#events + 1] = "close"
        return uv.fs_close(...)
      end,
      fs_chmod = function(...)
        events[#events + 1] = "chmod"
        return uv.fs_chmod(...)
      end,
      fs_rename = function(...)
        events[#events + 1] = "rename"
        return uv.fs_rename(...)
      end,
    }),
  })

  local err = wait_for_callback(function(cb)
    isolated.atomic_write(target, "new bytes", 416, cb)
  end)

  h.eq(nil, err)
  h.eq("new bytes", h.read(target))
  h.eq(416, bit.band(uv.fs_stat(target).mode, 511))
  h.eq("write,fsync,close,chmod,rename", table.concat(events, ","))
  h.eq(1, #directory_entries(directory))
end)

h.test("cleans up every atomic-write lifecycle failure", function()
  local failures = {
    { operation = "fs_write", message = "write" },
    { operation = "fs_fsync", message = "fsync" },
    { operation = "fs_close", message = "close" },
    { operation = "fs_chmod", message = "chmod" },
    { operation = "fs_rename", message = "rename" },
  }

  for _, failure in ipairs(failures) do
    local directory = h.tempdir()
    local target = directory .. "/state"
    h.write(target, "old")
    local injected = false
    local real_closes = 0
    local overrides = {}

    overrides.fs_close = function(...)
      if failure.operation == "fs_close" and not injected then
        injected = true
        return nil, "injected close failure", "EIO"
      end
      local closed, err, code = uv.fs_close(...)
      if closed then
        real_closes = real_closes + 1
      end
      return closed, err, code
    end
    if failure.operation ~= "fs_close" then
      overrides[failure.operation] = function(...)
        if not injected then
          injected = true
          return nil, "injected " .. failure.message .. " failure", "EIO"
        end
        return uv[failure.operation](...)
      end
    end

    local isolated = fs._new({
      schedule = function(callback) callback() end,
      uv = uv_with(overrides),
    })
    local calls, callback_error = 0
    isolated.atomic_write(target, "new bytes", 416, function(err)
      calls = calls + 1
      callback_error = err
    end)

    h.eq(1, calls)
    h.eq("EIO", callback_error.code)
    h.matches(failure.message, callback_error.message)
    h.eq("old", h.read(target))
    h.eq(1, #directory_entries(directory))
    h.eq(1, real_closes)
  end
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

h.test("refuses cleanup through a symlinked parent", function()
  local recorded_root = h.tempdir()
  local outside = h.tempdir()
  local parent = recorded_root .. "/parent"
  local target = parent .. "/aichatter-session"
  h.symlink(outside, parent)
  h.mkdir(outside .. "/aichatter-session")
  h.write(outside .. "/aichatter-session/keep", "outside")

  local err = wait_for_callback(function(cb)
    fs.remove_tree_guarded(target, parent, cb)
  end)

  h.truthy(err)
  h.matches("symlink ancestor", err.message)
  h.eq("outside", h.read(outside .. "/aichatter-session/keep"))
end)

h.test("revalidates cleanup ancestry immediately before deletion", function()
  local recorded_root = h.tempdir()
  local outside = h.tempdir()
  local parent = recorded_root .. "/parent"
  local target = parent .. "/aichatter-session"
  h.mkdir(target)
  h.write(target .. "/original", "inside")
  h.mkdir(outside .. "/aichatter-session")
  h.write(outside .. "/aichatter-session/keep", "outside")
  local scheduled = {}
  local isolated = fs._new({
    schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end,
  })
  local calls, callback_error = 0

  isolated.remove_tree_guarded(target, parent, function(err)
    calls = calls + 1
    callback_error = err
  end)
  h.eq(1, #scheduled)
  assert(uv.fs_rename(parent, recorded_root .. "/parent-old"))
  h.symlink(outside, parent)
  table.remove(scheduled, 1)()

  h.eq(1, calls)
  h.truthy(callback_error)
  h.matches("symlink ancestor", callback_error.message)
  h.eq("outside", h.read(outside .. "/aichatter-session/keep"))
end)
