local default_diff = require("aichatter.diff")
local default_fs = require("aichatter.fs")
local default_path = require("aichatter.path")
local buffer = require("aichatter.buffer")

local function require_callback(callback)
  assert(type(callback) == "function", "callback function is required")
  local called = false
  return function(...)
    if called then return end
    called = true
    pcall(callback, ...)
  end
end

local function optional_callback(callback)
  return require_callback(callback or function() end)
end

local function error_value(err)
  return type(err) == "table" and err or { message = tostring(err) }
end

local function same_identity(left, right)
  return left and right and left.dev ~= nil and left.ino ~= nil
    and left.dev == right.dev and left.ino == right.ino
end

local function identity(stat)
  return stat and { dev = stat.dev, ino = stat.ino } or nil
end

local function same_timestamp(left, right)
  return left and right and left.sec == right.sec and left.nsec == right.nsec
end

local function same_version(left, right)
  return same_identity(left, right) and left.size == right.size
    and bit.band(left.mode, 511) == bit.band(right.mode, 511)
    and same_timestamp(left.mtime, right.mtime)
    and same_timestamp(left.ctime, right.ctime)
end

local function new(dependencies)
  dependencies = dependencies or {}
  local diff = dependencies.diff or default_diff
  local fs = dependencies.fs or default_fs
  local path = dependencies.path or default_path
  local schedule = dependencies.schedule or vim.schedule
  local uv = dependencies.uv or vim.uv or vim.loop
  local Live = {}
  Live.__index = Live

  local function failure(code, message)
    return { code = code, message = message }
  end

  local function open_flags()
    local constants = uv.constants or {}
    if type(constants.O_RDONLY) == "number" and type(constants.O_NOFOLLOW) == "number" then
      return bit.bor(constants.O_RDONLY, constants.O_NOFOLLOW)
    end
    return "r"
  end

  function Live.new(root)
    local root_alias = path.normalize(root)
    local initial, err, code = uv.fs_lstat(root_alias)
    if not initial then
      error(failure(code, err or "could not inspect live root"), 0)
    elseif initial.type ~= "directory" and initial.type ~= "link" then
      error(failure("not_directory", "live root must be a directory"), 0)
    end
    local real, real_err, real_code = uv.fs_realpath(root_alias)
    if not real then
      error(failure(real_code, real_err or "could not resolve live root"), 0)
    end
    real = path.normalize(real)
    local anchored, anchor_err, anchor_code = uv.fs_lstat(real)
    if not anchored or anchored.type ~= "directory" then
      error(failure(anchor_code, anchor_err or "could not anchor live root"), 0)
    end
    return setmetatable({
      root = real,
      _root_alias = root_alias ~= real and root_alias or nil,
      _root_identity = identity(anchored),
    }, Live)
  end

  function Live:_resolve(relative)
    local ok, absolute = pcall(path.normalize, relative, self.root)
    if not ok or absolute == self.root or not path.is_within(self.root, absolute) then
      return nil, failure("outside_root", "path must resolve strictly inside the live root")
    end
    return absolute
  end

  function Live:_root_stat()
    local stat, err, code = uv.fs_lstat(self.root)
    if not stat or stat.type ~= "directory" or not same_identity(stat, self._root_identity) then
      return nil, failure("root_changed", err or code or "live root identity changed")
    end
    if self._root_alias then
      local alias_real, alias_err, alias_code = uv.fs_realpath(self._root_alias)
      if not alias_real or path.normalize(alias_real) ~= self.root then
        return nil, failure("root_changed", alias_err or alias_code or "live root alias changed")
      end
    end
    return stat
  end

  function Live:_inspect(absolute)
    local _, root_err = self:_root_stat()
    if root_err then return nil, root_err end
    local parts = {}
    for component in path.relative(self.root, absolute):gmatch("[^/]+") do
      parts[#parts + 1] = component
    end
    local current = self.root
    for index, component in ipairs(parts) do
      current = current .. "/" .. component
      local stat, err, code = uv.fs_lstat(current)
      if not stat then
        if code == "ENOENT" then return nil end
        return nil, failure(code, err or "could not inspect " .. current)
      end
      local final = index == #parts
      if stat.type == "link" then
        if final then return stat end
        return nil, failure("symlink_ancestor", "symlink in live path: " .. current)
      elseif not final and stat.type ~= "directory" then
        return nil, failure("not_directory", "non-directory ancestor: " .. current)
      elseif final and stat.type ~= "file" then
        return nil, failure("not_file", "live path is not a file: " .. current)
      elseif final then
        return stat
      end
    end
  end

  function Live:_translate_buffer_name(name)
    local normalized = path.normalize(name)
    if self._root_alias and (normalized == self._root_alias
      or path.is_within(self._root_alias, normalized)) then
      local current_alias = uv.fs_realpath(self._root_alias)
      if not current_alias or path.normalize(current_alias) ~= self.root then return end
      local relative = path.relative(self._root_alias, normalized)
      return relative == "." and self.root or self.root .. "/" .. relative
    end
    return normalized
  end

  function Live:_loaded_buffer(absolute)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and self:_translate_buffer_name(name) == absolute then return bufnr end
      end
    end
  end

  function Live:loaded_paths()
    local included, result = {}, {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        local ok, absolute = pcall(self._translate_buffer_name, self, name)
        if name ~= "" and ok and absolute and absolute ~= self.root
          and path.is_within(self.root, absolute) then
          local relative = path.relative(self.root, absolute)
          if not included[relative] then
            included[relative] = true
            result[#result + 1] = relative
          end
        end
      end
    end
    table.sort(result)
    return result
  end

  function Live:_disk_snapshot(absolute)
    local before, inspect_err = self:_inspect(absolute)
    if inspect_err then return nil, inspect_err end
    if not before then return { exists = false, disk_exists = false } end
    if before.type == "link" then
      local target, target_err, target_code = uv.fs_readlink(absolute)
      if not target then return nil, failure(target_code, target_err or "could not read link") end
      local after, after_err = self:_inspect(absolute)
      if after_err then return nil, after_err end
      local after_target = after and uv.fs_readlink(absolute)
      if not after or after.type ~= "link" or not same_identity(before, after)
        or after_target ~= target then
        return nil, failure("changed", "live link changed while reading")
      end
      return {
        exists = true,
        disk_exists = true,
        kind = "link",
        target = target,
        identity = identity(after),
      }
    end
    local fd, open_err, open_code = uv.fs_open(absolute, open_flags(), 0)
    if not fd then return nil, failure(open_code, open_err or "could not open " .. absolute) end
    local chunks = {}
    local ok, opened = xpcall(function()
      local stat, stat_err, stat_code = uv.fs_fstat(fd)
      if not stat then error(failure(stat_code, stat_err or "could not stat open file"), 0) end
      if not same_version(before, stat) then error(failure("changed", "live file changed while opening"), 0) end
      local offset = 0
      while offset < stat.size do
        local bytes, read_err, read_code = uv.fs_read(fd, math.min(65536, stat.size - offset), offset)
        if bytes == nil then error(failure(read_code, read_err or "could not read " .. absolute), 0) end
        if bytes == "" then break end
        chunks[#chunks + 1] = bytes
        offset = offset + #bytes
      end
      return stat
    end, function(err) return err end)
    local closed, close_err, close_code = uv.fs_close(fd)
    if not ok then return nil, error_value(opened) end
    if not closed then return nil, failure(close_code, close_err or "could not close " .. absolute) end
    local after, after_err = self:_inspect(absolute)
    if after_err then return nil, after_err end
    if not after or not same_version(opened, after) then
      return nil, failure("changed", "live file changed while reading")
    end
    local bytes = table.concat(chunks)
    return {
      exists = true,
      disk_exists = true,
      kind = "file",
      bytes = bytes,
      disk_bytes = bytes,
      mode = bit.band(after.mode, 511),
      identity = identity(after),
    }
  end

  function Live:snapshot(relative)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then return nil, resolve_err end
    local disk, disk_err = self:_disk_snapshot(absolute)
    if disk_err then return nil, disk_err end
    if disk.kind == "link" then return disk end
    local bufnr = self:_loaded_buffer(absolute)
    if not bufnr then return disk end
    local ok, bytes = pcall(buffer.bytes, bufnr)
    if not ok then return nil, error_value(bytes) end
    return {
      exists = true,
      kind = "file",
      disk_exists = disk.disk_exists,
      disk_bytes = disk.disk_bytes,
      bytes = bytes,
      mode = disk.mode,
      identity = disk.identity,
      bufnr = bufnr,
      changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      endofline = vim.bo[bufnr].endofline,
      modified = vim.bo[bufnr].modified,
      buffer_name = vim.api.nvim_buf_get_name(bufnr),
      modifiable = vim.bo[bufnr].modifiable,
      readonly = vim.bo[bufnr].readonly,
    }
  end

  local function matches(expected, current)
    local expected_kind = expected.kind or (expected.exists and "file" or nil)
    local current_kind = current.kind or (current.exists and "file" or nil)
    if expected.exists ~= current.exists or expected_kind ~= current_kind then
      return false
    end
    if expected_kind == "link" then
      if expected.target ~= current.target then return false end
    elseif expected.bytes ~= current.bytes or expected.mode ~= current.mode then
      return false
    end
    if expected.disk_exists ~= nil and (expected.disk_exists ~= current.disk_exists
      or expected.disk_bytes ~= current.disk_bytes) then
      return false
    end
    if expected.identity and not same_identity(expected.identity, current.identity) then return false end
    if expected.bufnr ~= current.bufnr then return false end
    if expected.bufnr and (expected.changedtick ~= current.changedtick
      or expected.buffer_name ~= current.buffer_name
      or expected.modifiable ~= current.modifiable
      or expected.readonly ~= current.readonly) then
      return false
    end
    if expected.modified ~= nil and expected.modified ~= current.modified then return false end
    return true
  end

  function Live:_validate_expected(relative, expected)
    local current, err = self:snapshot(relative)
    if not current then return err or failure("changed", "live path disappeared") end
    if not matches(expected, current) then return failure("conflict", "live path changed after validation") end
  end

  function Live:read(relative)
    local snapshot, err = self:snapshot(relative)
    if not snapshot then return nil, err end
    if snapshot.kind == "link" then
      return nil, failure("not_file", "live path is a symlink")
    end
    return snapshot.exists and snapshot.bytes or nil
  end

  function Live:mode(relative)
    local snapshot, err = self:snapshot(relative)
    if not snapshot then return nil, err end
    return snapshot.mode
  end

  local function parse_guard(expected, callback)
    if type(expected) == "function" and callback == nil then return nil, expected end
    return expected, callback
  end

  function Live:_chmod_loaded(absolute, current, wanted)
    if not current.disk_exists or current.mode == wanted then return end
    local disk, disk_err = self:_disk_snapshot(absolute)
    if disk_err then return disk_err end
    if not disk.disk_exists or not same_identity(disk.identity, current.identity)
      or disk.disk_bytes ~= current.disk_bytes or disk.mode ~= current.mode then
      return failure("conflict", "live file changed before chmod")
    end
    local fd, open_err, open_code = uv.fs_open(absolute, open_flags(), 0)
    if not fd then return failure(open_code, open_err or "could not open for chmod") end
    local opened, stat_err, stat_code = uv.fs_fstat(fd)
    local chmod_ok, chmod_err, chmod_code
    if opened and same_identity(opened, current.identity) then
      if uv.fs_fchmod then
        chmod_ok, chmod_err, chmod_code = uv.fs_fchmod(fd, wanted)
      else
        uv.fs_close(fd)
        return failure("unsupported", "safe descriptor-relative chmod is unavailable")
      end
    end
    local closed, close_err, close_code = uv.fs_close(fd)
    if not opened then return failure(stat_code, stat_err or "could not stat chmod file") end
    if not same_identity(opened, current.identity) then return failure("conflict", "live file changed before chmod") end
    if not chmod_ok then return failure(chmod_code, chmod_err or "could not chmod live file") end
    if not closed then
      local restore_fd, restore_open_err, restore_open_code = uv.fs_open(absolute, open_flags(), 0)
      if not restore_fd then
        return failure("rollback_failed", restore_open_err or restore_open_code
          or "could not reopen file to roll back mode")
      end
      local restore_stat = uv.fs_fstat(restore_fd)
      local restored, restore_err, restore_code
      if restore_stat and same_identity(restore_stat, current.identity) then
        restored, restore_err, restore_code = uv.fs_fchmod(restore_fd, current.mode)
      end
      uv.fs_close(restore_fd)
      if not restore_stat or not same_identity(restore_stat, current.identity) or not restored then
        return failure("rollback_failed", restore_err or restore_code
          or "could not roll back live file mode")
      end
      return failure(close_code, close_err or "could not close chmod file")
    end
  end

  function Live:write(relative, bytes, mode, expected, callback)
    expected, callback = parse_guard(expected, callback)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      callback = require_callback(callback)
      callback(resolve_err)
      return
    end
    local current, current_err = self:snapshot(relative)
    if not current then
      callback = require_callback(callback)
      callback(current_err)
      return
    end
    local bufnr = current.kind ~= "link" and current.bufnr or nil
    if bufnr then
      callback = optional_callback(callback)
      if expected and not matches(expected, current) then
        callback(failure("conflict", "live buffer changed after validation")); return
      end
      if not vim.bo[bufnr].modifiable then
        callback(failure("unmodifiable_buffer", "loaded buffer is not modifiable")); return
      end
      local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local old_endofline, old_modified = vim.bo[bufnr].endofline, vim.bo[bufnr].modified
      local parsed = diff.lines(bytes)
      local changed, change_err = pcall(function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, parsed.lines)
        vim.bo[bufnr].endofline = parsed.endofline
      end)
      if not changed then
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, old_lines)
        pcall(function()
          vim.bo[bufnr].endofline = old_endofline
          vim.bo[bufnr].modified = old_modified
        end)
        callback(error_value(change_err))
        return
      end
      local chmod_err = self:_chmod_loaded(absolute, current, bit.band(mode or 420, 511))
      if chmod_err then
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, old_lines)
        vim.bo[bufnr].endofline = old_endofline
        vim.bo[bufnr].modified = old_modified
        callback(chmod_err)
      else
        callback()
      end
      return
    end

    callback = require_callback(callback)
    if expected and not matches(expected, current) then
      callback(failure("conflict", "live file changed after validation")); return
    end
    expected = expected or current
    local ok, thrown = pcall(fs.atomic_write, absolute, bytes, mode, {
      before_commit = function() return self:_validate_expected(relative, expected) end,
    }, callback)
    if not ok then callback(error_value(thrown)) end
  end

  function Live:write_link(relative, target, expected, callback)
    expected, callback = parse_guard(expected, callback)
    callback = require_callback(callback)
    if type(target) ~= "string" then
      callback(failure("invalid_target", "symlink target must be a string"))
      return
    end
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then callback(resolve_err); return end
    local current, current_err = self:snapshot(relative)
    if not current then callback(current_err); return end
    if expected and not matches(expected, current) then
      callback(failure("conflict", "live link changed after validation")); return
    end
    expected = expected or current
    local ok, thrown = pcall(fs.atomic_symlink, absolute, target, {
      before_commit = function() return self:_validate_expected(relative, expected) end,
    }, callback)
    if not ok then callback(error_value(thrown)) end
  end

  function Live:delete(relative, expected, callback)
    expected, callback = parse_guard(expected, callback)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      callback = require_callback(callback)
      callback(resolve_err)
      return
    end
    callback = require_callback(callback)
    local current, current_err = self:snapshot(relative)
    if not current then callback(current_err); return end
    local bufnr = current.kind ~= "link" and current.bufnr or nil
    if bufnr and vim.bo[bufnr].modified then
      callback(failure("modified_buffer", "refusing to delete a modified loaded buffer"))
      return
    end
    if expected and not matches(expected, current) then
      callback(failure("conflict", "live path changed after validation")); return
    end
    expected = expected or current
    schedule(function()
      local guard_err = self:_validate_expected(relative, expected)
      if guard_err then callback(guard_err); return end
      local stat, inspect_err = self:_inspect(absolute)
      if inspect_err then callback(inspect_err); return end
      if stat then
        local removed, remove_err, remove_code = uv.fs_unlink(absolute)
        if not removed then callback(failure(remove_code, remove_err or "could not unlink " .. absolute)); return end
      end
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        local deleted, delete_err = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
        if not deleted and current.disk_exists then
          fs.atomic_write(absolute, current.disk_bytes, current.mode or 420, {
            before_commit = function()
              local disk, disk_err = self:_disk_snapshot(absolute)
              if not disk then return disk_err end
              if disk.disk_exists then return failure("conflict", "live path recreated before rollback") end
            end,
          }, function(restore_err) callback(restore_err or error_value(delete_err)) end)
          return
        elseif not deleted then
          callback(error_value(delete_err)); return
        end
      end
      callback()
    end)
  end

  function Live:restore(relative, before, expected, callback)
    callback = require_callback(callback)
    local current, current_err = self:snapshot(relative)
    if not current then callback(current_err); return end
    if not matches(expected, current) then
      callback(failure("conflict", "live path changed before rollback"))
      return
    end
    if before.kind == "link" then
      self:write_link(relative, before.target, current, callback)
    elseif before.bufnr then
      if current.bufnr ~= before.bufnr or not vim.api.nvim_buf_is_valid(before.bufnr)
        or not vim.api.nvim_buf_is_loaded(before.bufnr) then
        callback(failure("rollback_unavailable", "original loaded buffer no longer exists"))
        return
      end
      self:write(relative, before.bytes, before.mode or 420, current, function(write_err)
        if write_err then callback(write_err); return end
        local restored = vim.api.nvim_buf_is_valid(before.bufnr)
          and vim.api.nvim_buf_is_loaded(before.bufnr)
          and vim.api.nvim_buf_get_name(before.bufnr) == before.buffer_name
        if not restored then
          callback(failure("rollback_unavailable", "original loaded buffer changed during rollback"))
          return
        end
        local ok, state_err = pcall(function()
          vim.bo[before.bufnr].endofline = before.endofline
          vim.bo[before.bufnr].readonly = before.readonly
          vim.bo[before.bufnr].modified = before.modified
          vim.bo[before.bufnr].modifiable = before.modifiable
        end)
        if ok then callback() else callback(error_value(state_err)) end
      end)
    elseif before.exists then
      self:write(relative, before.bytes, before.mode or 420, current, callback)
    else
      self:delete(relative, current, callback)
    end
  end

  return Live
end

local Live = new()
Live._new = new
return Live
