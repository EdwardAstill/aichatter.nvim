local h = require("tests.helpers")
local manifest = require("aichatter.manifest")
local real_uv = vim.uv or vim.loop

local function uv_with(overrides)
  return setmetatable(overrides, { __index = real_uv })
end

local function scan_with(scanner, root)
  local calls, failure, result = 0
  scanner.scan(root, {}, function(err, value)
    calls = calls + 1
    failure, result = err, value
  end)
  return failure, result, calls
end

local function scan(root, opts)
  local result, failure
  manifest.scan(root, opts or {}, function(err, value)
    failure, result = err, value
  end)
  assert(h.wait_for(function() return failure ~= nil or result ~= nil end, 2000),
    "timed out scanning manifest")
  assert(not failure, vim.inspect(failure))
  return result
end

h.test("classifies modified, created, and deleted paths", function()
  local base, candidate = h.tempdir(), h.tempdir()
  h.write(base .. "/modified.txt", "old\n")
  h.write(candidate .. "/modified.txt", "new\n")
  h.write(base .. "/deleted.txt", "gone\n")
  h.write(candidate .. "/created.txt", "here\n")

  local changes = h.scan_changes(base, candidate)

  h.eq("modified", changes["modified.txt"].kind)
  h.eq("deleted", changes["deleted.txt"].kind)
  h.eq("created", changes["created.txt"].kind)
  h.eq("modified.txt", changes["modified.txt"].path)
  h.eq(nil, changes["unchanged.txt"])
end)

h.test("records regular file content metadata including empty files", function()
  local root = h.tempdir()
  h.write(root .. "/empty", "")
  h.write(root .. "/binary", "abc\0def")
  h.chmod(root .. "/empty", 493)

  local entries = scan(root)

  h.eq({
    kind = "file",
    size = 0,
    mode = 493,
    digest = vim.fn.sha256(""),
    binary = false,
  }, entries.empty)
  h.eq(7, entries.binary.size)
  h.eq(vim.fn.sha256("abc\0def"), entries.binary.digest)
  h.truthy(entries.binary.binary)
end)

h.test("classifies a mode-only regular file change", function()
  local base, candidate = h.tempdir(), h.tempdir()
  h.write(base .. "/script", "same\n")
  h.write(candidate .. "/script", "same\n")
  h.chmod(base .. "/script", 420)
  h.chmod(candidate .. "/script", 493)

  local change = h.scan_changes(base, candidate).script

  h.eq("modified", change.kind)
  h.eq(420, change.before.mode)
  h.eq(493, change.after.mode)
  h.eq(change.before.digest, change.after.digest)
end)

h.test("records and compares symlink targets without following them", function()
  local base, candidate = h.tempdir(), h.tempdir()
  local outside = h.tempdir()
  h.write(outside .. "/secret", "outside\n")
  h.symlink(outside, base .. "/linked-directory")
  h.symlink("first", base .. "/changed-link")
  h.symlink("second", candidate .. "/changed-link")
  h.symlink(outside, candidate .. "/linked-directory")

  local base_entries = scan(base)
  local changes = h.scan_changes(base, candidate)

  h.eq({ kind = "link", target = outside }, base_entries["linked-directory"])
  h.eq(nil, base_entries["linked-directory/secret"])
  h.eq("modified", changes["changed-link"].kind)
  h.eq("first", changes["changed-link"].before.target)
  h.eq("second", changes["changed-link"].after.target)
  h.eq(nil, changes["linked-directory"])
end)

h.test("excludes every .git directory from manifests", function()
  local root = h.tempdir()
  h.mkdir(root .. "/.git/nested")
  h.write(root .. "/.git/index", "ignored")
  h.write(root .. "/.git/nested/config", "ignored")
  h.mkdir(root .. "/src/.git")
  h.write(root .. "/src/.git/also-ignored", "ignored")
  h.write(root .. "/kept", "kept")

  local entries = scan(root)

  h.eq(nil, entries[".git/index"])
  h.eq(nil, entries["src/.git/also-ignored"])
  h.truthy(entries.kept)
end)

h.test("omits unchanged regular files and links", function()
  local before = {
    file = { kind = "file", size = 1, mode = 420, digest = "same", binary = false },
    link = { kind = "link", target = "target" },
  }
  local after = vim.deepcopy(before)

  h.eq({}, manifest.compare(before, after))
end)

h.test("yields at the manifest batch boundary and cancels exactly once", function()
  local root = h.tempdir()
  for index = 1, 140 do
    h.write(root .. string.format("/file-%03d", index), tostring(index))
  end
  local scheduled = {}
  local isolated = manifest._new({
    schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end,
  })
  local cancel = { cancelled = false }
  local calls, callback_error = 0

  isolated.scan(root, { cancel = cancel }, function(err)
    calls = calls + 1
    callback_error = err
  end)

  h.eq(1, #scheduled)
  table.remove(scheduled, 1)()
  h.eq(0, calls)
  h.eq(1, #scheduled)
  cancel.cancelled = true
  local cancelled_batch = table.remove(scheduled, 1)
  cancelled_batch()
  cancelled_batch()

  h.eq(1, calls)
  h.eq("cancelled", callback_error.code)
end)

h.test("requests no-follow open semantics when libuv exposes them", function()
  local root = h.tempdir()
  h.write(root .. "/file", "safe")
  local opened_flags
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      constants = { O_RDONLY = 0, O_NOFOLLOW = 131072 },
      fs_open = function(path, flags, mode)
        opened_flags = flags
        return real_uv.fs_open(path, "r", mode)
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(nil, failure)
  h.eq(1, calls)
  h.eq("file", entries.file.kind)
  h.eq(131072, bit.band(opened_flags, 131072))
end)

h.test("rejects a file replaced by a symlink between lstat and open before reading", function()
  local root = h.tempdir()
  local outside = h.tempdir() .. "/outside"
  local target = root .. "/file"
  h.write(target, "inside")
  h.write(outside, "outside")
  local replaced = false
  local reads = 0
  local closes = 0
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      constants = {},
      fs_lstat = function(path)
        local stat, err, code = real_uv.fs_lstat(path)
        if path == target and not replaced then
          replaced = true
          assert(real_uv.fs_unlink(path))
          assert(real_uv.fs_symlink(outside, path))
        end
        return stat, err, code
      end,
      fs_read = function(...)
        reads = reads + 1
        return real_uv.fs_read(...)
      end,
      fs_close = function(...)
        closes = closes + 1
        return real_uv.fs_close(...)
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(1, calls)
  h.eq("changed", failure.code)
  h.matches("changed while opening", failure.message)
  h.eq(nil, entries)
  h.eq(0, reads)
  h.eq(1, closes)
  h.eq("outside", h.read(outside))
end)

h.test("reports open failure without attempting to close a descriptor", function()
  local root = h.tempdir()
  h.write(root .. "/file", "content")
  local closes = 0
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      fs_open = function()
        return nil, "open denied", "EOPEN"
      end,
      fs_close = function(...)
        closes = closes + 1
        return real_uv.fs_close(...)
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(1, calls)
  h.eq("EOPEN", failure.code)
  h.matches("open denied", failure.message)
  h.eq(nil, entries)
  h.eq(0, closes)
end)

h.test("closes the descriptor and reports a read failure exactly once", function()
  local root = h.tempdir()
  h.write(root .. "/file", "content")
  local descriptors = {}
  local closes = 0
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      fs_open = function(...)
        local fd, err, code = real_uv.fs_open(...)
        if fd then
          descriptors[fd] = true
        end
        return fd, err, code
      end,
      fs_read = function()
        return nil, "read failed", "EREAD"
      end,
      fs_close = function(fd)
        closes = closes + 1
        descriptors[fd] = nil
        return real_uv.fs_close(fd)
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(1, calls)
  h.eq("EREAD", failure.code)
  h.matches("read failed", failure.message)
  h.eq(nil, entries)
  h.eq(1, closes)
  h.eq(nil, next(descriptors))
end)

h.test("closes the descriptor and reports close failure exactly once", function()
  local root = h.tempdir()
  h.write(root .. "/file", "content")
  local descriptors = {}
  local closes = 0
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      fs_open = function(...)
        local fd, err, code = real_uv.fs_open(...)
        if fd then
          descriptors[fd] = true
        end
        return fd, err, code
      end,
      fs_close = function(fd)
        closes = closes + 1
        descriptors[fd] = nil
        assert(real_uv.fs_close(fd))
        return nil, "close failed", "ECLOSE"
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(1, calls)
  h.eq("ECLOSE", failure.code)
  h.matches("close failed", failure.message)
  h.eq(nil, entries)
  h.eq(1, closes)
  h.eq(nil, next(descriptors))
end)

h.test("preserves read failure precedence when closing also fails", function()
  local root = h.tempdir()
  h.write(root .. "/file", "content")
  local closes = 0
  local isolated = manifest._new({
    schedule = function(callback) callback() end,
    uv = uv_with({
      fs_read = function()
        return nil, "read failed first", "EREAD"
      end,
      fs_close = function(fd)
        closes = closes + 1
        assert(real_uv.fs_close(fd))
        return nil, "close failed second", "ECLOSE"
      end,
    }),
  })

  local failure, entries, calls = scan_with(isolated, root)

  h.eq(1, calls)
  h.eq("EREAD", failure.code)
  h.matches("read failed first", failure.message)
  h.eq(nil, entries)
  h.eq(1, closes)
end)
