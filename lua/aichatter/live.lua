local default_diff = require("aichatter.diff")
local default_fs = require("aichatter.fs")
local default_path = require("aichatter.path")

local function once(callback)
  callback = callback or function() end
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    pcall(callback, ...)
  end
end

local function error_value(err)
  if type(err) == "table" then
    return err
  end
  return { message = tostring(err) }
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

  function Live.new(root)
    return setmetatable({ root = path.normalize(root) }, Live)
  end

  function Live:_resolve(relative)
    local ok, absolute = pcall(path.normalize, relative, self.root)
    if not ok or absolute == self.root or not path.is_within(self.root, absolute) then
      return nil, {
        code = "outside_root",
        message = "path must resolve strictly inside the live root",
      }
    end
    return absolute
  end

  function Live:_loaded_buffer(absolute)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and path.normalize(name) == absolute then
          return bufnr
        end
      end
    end
  end

  function Live:loaded_paths()
    local included = {}
    local result = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        local ok, absolute = pcall(path.normalize, name)
        if name ~= "" and ok and absolute ~= self.root
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

  local function buffer_bytes(bufnr)
    local bytes = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if vim.bo[bufnr].endofline then
      bytes = bytes .. "\n"
    end
    return bytes
  end

  function Live:read(relative)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      return nil, resolve_err
    end
    local bufnr = self:_loaded_buffer(absolute)
    if bufnr then
      local ok, bytes = pcall(buffer_bytes, bufnr)
      if ok then
        return bytes
      end
      return nil, error_value(bytes)
    end
    local file, open_err = io.open(absolute, "rb")
    if not file then
      local stat, _, code = uv.fs_stat(absolute)
      if not stat and code == "ENOENT" then
        return nil
      end
      return nil, { code = code, message = open_err or "could not open " .. absolute }
    end
    local bytes = file:read("*a")
    file:close()
    return bytes
  end

  function Live:mode(relative)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      return nil, resolve_err
    end
    local stat, err, code = uv.fs_stat(absolute)
    if not stat then
      if code == "ENOENT" then
        return nil
      end
      return nil, { code = code, message = err or "could not stat " .. absolute }
    end
    return bit.band(stat.mode, 511)
  end

  function Live:write(relative, bytes, mode, callback)
    callback = once(callback)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      callback(resolve_err)
      return
    end
    local bufnr = self:_loaded_buffer(absolute)
    if bufnr then
      local parsed = diff.lines(bytes)
      local ok, err = pcall(function()
        local stat, stat_err, stat_code = uv.fs_stat(absolute)
        if stat then
          local wanted_mode = bit.band(mode or 420, 511)
          if bit.band(stat.mode, 511) ~= wanted_mode then
            local changed, chmod_err, chmod_code = uv.fs_chmod(absolute, wanted_mode)
            if not changed then
              error({ code = chmod_code, message = chmod_err or "could not chmod " .. absolute }, 0)
            end
          end
        elseif stat_code ~= "ENOENT" then
          error({ code = stat_code, message = stat_err or "could not stat " .. absolute }, 0)
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, parsed.lines)
        vim.bo[bufnr].endofline = parsed.endofline
      end)
      if ok then
        callback()
      else
        callback(error_value(err))
      end
      return
    end
    local ok, err = pcall(fs.atomic_write, absolute, bytes, mode, callback)
    if not ok then
      callback(error_value(err))
    end
  end

  local function check_parent(root, absolute)
    local relative = path.relative(root, vim.fs.dirname(absolute))
    if relative == "." then
      return
    end
    local current = root
    for component in relative:gmatch("[^/]+") do
      current = current .. "/" .. component
      local stat, err, code = uv.fs_lstat(current)
      if not stat then
        if code == "ENOENT" then
          return
        end
        error({ code = code, message = err or "could not inspect " .. current }, 0)
      end
      if stat.type == "link" then
        error({ code = "symlink_ancestor", message = "symlink ancestor: " .. current }, 0)
      elseif stat.type ~= "directory" then
        error({ code = "not_directory", message = "non-directory ancestor: " .. current }, 0)
      end
    end
  end

  function Live:delete(relative, callback)
    callback = once(callback)
    local absolute, resolve_err = self:_resolve(relative)
    if not absolute then
      callback(resolve_err)
      return
    end
    local bufnr = self:_loaded_buffer(absolute)
    if bufnr and vim.bo[bufnr].modified then
      callback({
        code = "modified_buffer",
        message = "refusing to delete a modified loaded buffer",
      })
      return
    end

    schedule(function()
      local ok, err = xpcall(function()
        check_parent(self.root, absolute)
        local stat, stat_err, stat_code = uv.fs_lstat(absolute)
        if not stat then
          if stat_code ~= "ENOENT" then
            error({ code = stat_code, message = stat_err or "could not stat " .. absolute }, 0)
          end
        elseif stat.type == "directory" then
          error({ code = "is_directory", message = "refusing to delete directory " .. absolute }, 0)
        else
          local removed, remove_err, remove_code = uv.fs_unlink(absolute)
          if not removed then
            error({ code = remove_code, message = remove_err or "could not unlink " .. absolute }, 0)
          end
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = false })
        end
      end, function(value) return value end)
      if ok then
        callback()
      else
        callback(error_value(err))
      end
    end)
  end

  return Live
end

local Live = new()
Live._new = new
return Live
