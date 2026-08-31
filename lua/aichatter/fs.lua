local path = require("aichatter.path")

local M = {}
local uv = vim.uv or vim.loop
local atomic_counter = 0

local function identity(value)
  return value
end

local function failure(message, code)
  error({ message = message, code = code }, 0)
end

local function check(value, err, code, operation, target)
  if value == nil then
    failure(string.format("%s %s: %s", operation, target, err or "unknown error"), code)
  end
  return value
end

local function permissions(mode)
  return bit.band(mode, 511)
end

local function close_fd(fd)
  if fd then
    uv.fs_close(fd)
  end
end

local function copy_file_bytes(source, target, mode)
  local source_fd, open_err, open_code = uv.fs_open(source, "r", 0)
  check(source_fd, open_err, open_code, "open", source)

  local target_fd, target_err, target_code = uv.fs_open(target, "w", permissions(mode))
  if not target_fd then
    close_fd(source_fd)
    check(target_fd, target_err, target_code, "open", target)
  end

  local ok, err = xpcall(function()
    local offset = 0
    while true do
      local bytes, read_err, read_code = uv.fs_read(source_fd, 65536, offset)
      check(bytes, read_err, read_code, "read", source)
      if bytes == "" then
        break
      end

      local written = 0
      while written < #bytes do
        local count, write_err, write_code = uv.fs_write(
          target_fd,
          bytes:sub(written + 1),
          offset + written
        )
        check(count, write_err, write_code, "write", target)
        if count == 0 then
          failure("write " .. target .. ": wrote zero bytes")
        end
        written = written + count
      end
      offset = offset + #bytes
    end
    local changed, chmod_err, chmod_code = uv.fs_chmod(target, permissions(mode))
    check(changed, chmod_err, chmod_code, "chmod", target)
  end, identity)

  close_fd(source_fd)
  close_fd(target_fd)
  if not ok then
    uv.fs_unlink(target)
    error(err, 0)
  end
end

local function enqueue_children(job, source, target, relative)
  local scan, scan_err, scan_code = uv.fs_scandir(source)
  check(scan, scan_err, scan_code, "scan", source)
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if not job.exclude[name] then
      job.queue[#job.queue + 1] = {
        source = source .. "/" .. name,
        target = target .. "/" .. name,
        relative = relative == "" and name or relative .. "/" .. name,
      }
    end
  end
end

local function copy_entry(job, entry)
  local stat, stat_err, stat_code = uv.fs_lstat(entry.source)
  check(stat, stat_err, stat_code, "lstat", entry.source)

  if stat.type == "directory" then
    local made, mkdir_err, mkdir_code = uv.fs_mkdir(entry.target, permissions(stat.mode))
    check(made, mkdir_err, mkdir_code, "mkdir", entry.target)
    enqueue_children(job, entry.source, entry.target, entry.relative)
  elseif stat.type == "link" then
    local link, read_err, read_code = uv.fs_readlink(entry.source)
    check(link, read_err, read_code, "readlink", entry.source)
    local made, link_err, link_code = uv.fs_symlink(link, entry.target)
    check(made, link_err, link_code, "symlink", entry.target)
  elseif stat.type == "file" then
    copy_file_bytes(entry.source, entry.target, stat.mode)
  else
    failure("unsupported file type at " .. entry.source)
  end
end

function M.copy_tree(source, target, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local job = {
    callback = callback,
    cancel = opts.cancel or {},
    exclude = opts.exclude or {},
    on_progress = opts.on_progress,
    queue = { {
      source = path.normalize(source),
      target = path.normalize(target),
      relative = "",
    } },
    next_entry = 1,
    copied = 0,
    finished = false,
  }

  local function finish(err)
    if job.finished then
      return
    end
    job.finished = true
    pcall(job.callback, err)
  end

  local run_batch
  run_batch = function()
    if job.finished then
      return
    end

    local processed = 0
    while processed < 128 and job.next_entry <= #job.queue do
      if job.cancel.cancelled then
        finish({ code = "cancelled", message = "copy cancelled" })
        return
      end

      local entry = job.queue[job.next_entry]
      job.next_entry = job.next_entry + 1
      local ok, err = xpcall(function()
        copy_entry(job, entry)
        job.copied = job.copied + 1
        if job.on_progress then
          job.on_progress(job.copied, entry.relative)
        end
      end, identity)
      if not ok then
        finish(type(err) == "table" and err or { message = tostring(err) })
        return
      end
      processed = processed + 1
    end

    if job.cancel.cancelled then
      finish({ code = "cancelled", message = "copy cancelled" })
    elseif job.next_entry > #job.queue then
      finish()
    else
      vim.schedule(run_batch)
    end
  end

  vim.schedule(run_batch)
end

local function write_all(fd, target, bytes)
  local offset = 0
  while offset < #bytes do
    local count, err, code = uv.fs_write(fd, bytes:sub(offset + 1), offset)
    check(count, err, code, "write", target)
    if count == 0 then
      failure("write " .. target .. ": wrote zero bytes")
    end
    offset = offset + count
  end
end

function M.atomic_write(target, bytes, mode, callback)
  callback = callback or function() end
  target = path.normalize(target)
  local called = false

  local function finish(err)
    if called then
      return
    end
    called = true
    pcall(callback, err)
  end

  vim.schedule(function()
    local temp
    local fd
    local ok, err = xpcall(function()
      for _ = 1, 10 do
        atomic_counter = atomic_counter + 1
        temp = string.format("%s.aichatter-tmp-%d-%d", target, uv.os_getpid(), atomic_counter)
        local open_err, open_code
        fd, open_err, open_code = uv.fs_open(temp, "wx", permissions(mode))
        if fd then
          break
        end
        if open_code ~= "EEXIST" then
          check(fd, open_err, open_code, "open", temp)
        end
      end
      if not fd then
        failure("could not create a unique temporary sibling for " .. target)
      end

      write_all(fd, temp, bytes)
      local synced, sync_err, sync_code = uv.fs_fsync(fd)
      check(synced, sync_err, sync_code, "fsync", temp)
      local changed, chmod_err, chmod_code = uv.fs_chmod(temp, permissions(mode))
      check(changed, chmod_err, chmod_code, "chmod", temp)
      local closed, close_err, close_code = uv.fs_close(fd)
      check(closed, close_err, close_code, "close", temp)
      fd = nil
      local renamed, rename_err, rename_code = uv.fs_rename(temp, target)
      check(renamed, rename_err, rename_code, "rename", target)
      temp = nil
    end, identity)

    close_fd(fd)
    if temp then
      uv.fs_unlink(temp)
    end
    local callback_error
    if not ok then
      callback_error = type(err) == "table" and err or { message = tostring(err) }
    end
    finish(callback_error)
  end)
end

local function remove_entry(target)
  local stat, stat_err, stat_code = uv.fs_lstat(target)
  if not stat then
    if stat_code == "ENOENT" then
      return
    end
    check(stat, stat_err, stat_code, "lstat", target)
  end

  if stat.type == "directory" then
    local scan, scan_err, scan_code = uv.fs_scandir(target)
    check(scan, scan_err, scan_code, "scan", target)
    while true do
      local name = uv.fs_scandir_next(scan)
      if not name then
        break
      end
      remove_entry(target .. "/" .. name)
    end
    local removed, remove_err, remove_code = uv.fs_rmdir(target)
    check(removed, remove_err, remove_code, "rmdir", target)
  else
    local removed, remove_err, remove_code = uv.fs_unlink(target)
    check(removed, remove_err, remove_code, "unlink", target)
  end
end

function M.remove_tree_guarded(target, expected_parent, callback)
  callback = callback or function() end
  target = path.normalize(target)
  expected_parent = path.normalize(expected_parent)

  local validation_error
  if target == expected_parent then
    validation_error = { message = "target must be strictly inside expected parent" }
  elseif not path.is_within(expected_parent, target) then
    validation_error = { message = "target outside expected parent" }
  elseif not vim.fs.basename(target):match("^aichatter%-") then
    validation_error = { message = "target basename must begin with aichatter-" }
  end

  if validation_error then
    pcall(callback, validation_error)
    return
  end

  vim.schedule(function()
    local ok, err = xpcall(function()
      remove_entry(target)
    end, identity)
    local callback_error
    if not ok then
      callback_error = type(err) == "table" and err or { message = tostring(err) }
    end
    pcall(callback, callback_error)
  end)
end

return M
