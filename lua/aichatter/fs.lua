local path = require("aichatter.path")

local function new(dependencies)
dependencies = dependencies or {}
local M = {}
local uv = dependencies.uv or vim.uv or vim.loop
local schedule = dependencies.schedule or vim.schedule
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

local function each_ancestor(directory, visitor)
  local current = "/"
  for component in directory:gmatch("[^/]+") do
    current = current == "/" and current .. component or current .. "/" .. component
    visitor(current)
  end
end

local function reject_symlink_ancestors(directory)
  local missing = false
  each_ancestor(directory, function(current)
    if missing then
      return
    end
    local stat, err, code = uv.fs_lstat(current)
    if not stat then
      if code == "ENOENT" then
        missing = true
        return
      end
      check(stat, err, code, "lstat", current)
    elseif stat.type == "link" then
      failure("symlink ancestor: " .. current)
    elseif stat.type ~= "directory" then
      failure("non-directory ancestor: " .. current)
    end
  end)
end

local function ensure_directory(directory)
  each_ancestor(directory, function(current)
    local stat, err, code = uv.fs_lstat(current)
    if stat then
      if stat.type == "link" then
        failure("symlink ancestor: " .. current)
      elseif stat.type ~= "directory" then
        failure("non-directory ancestor: " .. current)
      end
      return
    end
    if code ~= "ENOENT" then
      check(stat, err, code, "lstat", current)
    end
    local made, mkdir_err, mkdir_code = uv.fs_mkdir(current, 493)
    check(made, mkdir_err, mkdir_code, "mkdir", current)
  end)
end

local function open_unique_sibling(target, mode)
  for _ = 1, 10 do
    atomic_counter = atomic_counter + 1
    local temp = string.format("%s.aichatter-tmp-%d-%d", target, uv.os_getpid(), atomic_counter)
    local fd, err, code = uv.fs_open(temp, "wx", permissions(mode))
    if fd then
      return temp, fd
    end
    if code ~= "EEXIST" then
      check(fd, err, code, "open", temp)
    end
  end
  failure("could not create a unique temporary sibling for " .. target)
end

local function copy_file_bytes(source, target, mode)
  local source_fd, open_err, open_code = uv.fs_open(source, "r", 0)
  check(source_fd, open_err, open_code, "open", source)

  local temp
  local target_fd
  local opened, open_failure = xpcall(function()
    temp, target_fd = open_unique_sibling(target, mode)
  end, identity)
  if not opened then
    close_fd(source_fd)
    error(open_failure, 0)
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
    local synced, sync_err, sync_code = uv.fs_fsync(target_fd)
    check(synced, sync_err, sync_code, "fsync", temp)
    local closed, close_err, close_code = uv.fs_close(target_fd)
    check(closed, close_err, close_code, "close", temp)
    target_fd = nil
    local changed, chmod_err, chmod_code = uv.fs_chmod(temp, permissions(mode))
    check(changed, chmod_err, chmod_code, "chmod", temp)
    local renamed, rename_err, rename_code = uv.fs_rename(temp, target)
    check(renamed, rename_err, rename_code, "rename", target)
    temp = nil
  end, identity)

  close_fd(source_fd)
  close_fd(target_fd)
  if temp then
    uv.fs_unlink(temp)
  end
  if not ok then
    error(err, 0)
  end
end

local remove_entry

local function destination_stat(target)
  local stat, err, code = uv.fs_lstat(target)
  if not stat and code ~= "ENOENT" then
    check(stat, err, code, "lstat", target)
  end
  return stat
end

local function prepare_destination(job, target, wanted_type)
  local stat = destination_stat(target)
  if not stat then
    return false
  end
  if not job.overlay then
    failure("destination exists: " .. target, "EEXIST")
  end
  if wanted_type == "directory" and stat.type == "directory" then
    return true
  end
  if wanted_type == "file" and stat.type == "file" then
    return true
  end
  remove_entry(target)
  return false
end

local function is_excluded(job, name, relative)
  return job.exclude[relative] or (name == ".git" and job.exclude[".git"])
end

local function preserves_excluded_descendant(job, relative)
  if job.exclude[relative] then
    return true
  end
  local prefix = relative .. "/"
  for excluded in pairs(job.exclude) do
    if excluded:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function prune_missing_entry(job, target, name, relative)
  if is_excluded(job, name, relative) then
    return
  end
  if not preserves_excluded_descendant(job, relative) then
    remove_entry(target)
    return
  end
  local stat, stat_err, stat_code = uv.fs_lstat(target)
  check(stat, stat_err, stat_code, "lstat", target)
  if stat.type ~= "directory" then
    remove_entry(target)
    return
  end
  local scan, scan_err, scan_code = uv.fs_scandir(target)
  check(scan, scan_err, scan_code, "scan", target)
  while true do
    local child_name = uv.fs_scandir_next(scan)
    if not child_name then
      break
    end
    local child_relative = relative .. "/" .. child_name
    prune_missing_entry(job, target .. "/" .. child_name, child_name, child_relative)
  end
end

local function enqueue_children(job, source, target, relative)
  local source_names = {}
  local scan, scan_err, scan_code = uv.fs_scandir(source)
  check(scan, scan_err, scan_code, "scan", source)
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    source_names[name] = true
    local child_relative = relative == "" and name or relative .. "/" .. name
    if not is_excluded(job, name, child_relative) then
      job.queue[#job.queue + 1] = {
        source = source .. "/" .. name,
        target = target .. "/" .. name,
        relative = child_relative,
      }
    end
  end

  if job.prune then
    local target_scan, target_err, target_code = uv.fs_scandir(target)
    check(target_scan, target_err, target_code, "scan", target)
    while true do
      local name = uv.fs_scandir_next(target_scan)
      if not name then
        break
      end
      local child_relative = relative == "" and name or relative .. "/" .. name
      if not source_names[name] then
        prune_missing_entry(job, target .. "/" .. name, name, child_relative)
      end
    end
  end
end

local function copy_entry(job, entry)
  local stat, stat_err, stat_code = uv.fs_lstat(entry.source)
  check(stat, stat_err, stat_code, "lstat", entry.source)

  if stat.type == "directory" then
    local exists = prepare_destination(job, entry.target, "directory")
    if not exists then
      local made, mkdir_err, mkdir_code = uv.fs_mkdir(entry.target, permissions(stat.mode))
      check(made, mkdir_err, mkdir_code, "mkdir", entry.target)
    end
    enqueue_children(job, entry.source, entry.target, entry.relative)
  elseif stat.type == "link" then
    prepare_destination(job, entry.target, "link")
    local link, read_err, read_code = uv.fs_readlink(entry.source)
    check(link, read_err, read_code, "readlink", entry.source)
    local made, link_err, link_code = uv.fs_symlink(link, entry.target)
    check(made, link_err, link_code, "symlink", entry.target)
  elseif stat.type == "file" then
    prepare_destination(job, entry.target, "file")
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
    overlay = opts.overlay or false,
    prune = opts.prune or false,
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

    if not job.prepared then
      local prepared, prepare_err = xpcall(function()
        ensure_directory(vim.fs.dirname(job.queue[1].target))
      end, identity)
      if not prepared then
        finish(type(prepare_err) == "table" and prepare_err or { message = tostring(prepare_err) })
        return
      end
      job.prepared = true
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
      schedule(run_batch)
    end
  end

  schedule(run_batch)
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

function M.atomic_write(target, bytes, mode, opts, callback)
  if type(opts) == "function" or opts == nil then
    callback, opts = opts, {}
  end
  callback = callback or function() end
  opts = opts or {}
  target = path.normalize(target)
  local called = false

  local function finish(err)
    if called then
      return
    end
    called = true
    pcall(callback, err)
  end

  schedule(function()
    local temp
    local fd
    local ok, err = xpcall(function()
      ensure_directory(vim.fs.dirname(target))
      temp, fd = open_unique_sibling(target, mode)

      write_all(fd, temp, bytes)
      local synced, sync_err, sync_code = uv.fs_fsync(fd)
      check(synced, sync_err, sync_code, "fsync", temp)
      local closed, close_err, close_code = uv.fs_close(fd)
      check(closed, close_err, close_code, "close", temp)
      fd = nil
      local changed, chmod_err, chmod_code = uv.fs_chmod(temp, permissions(mode))
      check(changed, chmod_err, chmod_code, "chmod", temp)
      if opts.before_commit then
        local guard_err = opts.before_commit()
        if guard_err then
          error(guard_err, 0)
        end
      end
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

remove_entry = function(target)
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

  local ancestors_ok, ancestor_err = xpcall(function()
    reject_symlink_ancestors(vim.fs.dirname(target))
  end, identity)
  if not ancestors_ok then
    pcall(callback, type(ancestor_err) == "table" and ancestor_err
      or { message = tostring(ancestor_err) })
    return
  end

  schedule(function()
    local ok, err = xpcall(function()
      reject_symlink_ancestors(vim.fs.dirname(target))
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
end

local M = new()
M._new = new
return M
