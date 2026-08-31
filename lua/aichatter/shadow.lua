local default_fs = require("aichatter.fs")
local default_path = require("aichatter.path")

local function once(callback)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    callback(...)
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
  local fs = dependencies.fs or default_fs
  local path = dependencies.path or default_path
  local uv = dependencies.uv or vim.uv or vim.loop
  local session_counter = 0
  local Shadow = {}
  Shadow.__index = Shadow

  local function default_run(argv, callback)
    return vim.system(argv, { text = true }, function(result)
      callback(nil, result)
    end)
  end

  local function default_buffer_provider(root)
    local buffers = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if vim.api.nvim_buf_is_loaded(bufnr) and name ~= "" then
        name = path.normalize(name)
        if name ~= root and path.is_within(root, name) then
          local bytes = table.concat(
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            "\n"
          )
          if vim.bo[bufnr].endofline then
            bytes = bytes .. "\n"
          end
          local stat = uv.fs_stat(name)
          buffers[#buffers + 1] = {
            path = name,
            bytes = bytes,
            mode = stat and bit.band(stat.mode, 511) or 420,
          }
        end
      end
    end
    return buffers
  end

  local function command_error(label, argv, err, result)
    if err then
      err = error_value(err)
      return {
        argv = vim.deepcopy(argv),
        code = err.code,
        stderr = err.stderr or "",
        message = string.format("%s failed: %s", label, err.message or tostring(err)),
      }
    end
    return {
      argv = vim.deepcopy(argv),
      code = result and result.code,
      stderr = result and result.stderr or "",
      message = string.format("%s failed with exit code %s", label,
        tostring(result and result.code or "unknown")),
    }
  end

  local function mkdir(target)
    local made, err, code = uv.fs_mkdir(target, 493)
    if not made then
      return { code = code, message = string.format("mkdir %s: %s", target, err or "unknown error") }
    end
  end

  local function create_session_root(temp_parent)
    for _ = 1, 100 do
      session_counter = session_counter + 1
      local candidate = path.join(temp_parent, string.format(
        "aichatter-%d-%d",
        uv.os_getpid(),
        session_counter
      ))
      local err = mkdir(candidate)
      if not err then
        local control_err = mkdir(candidate .. "/control")
        if control_err then
          return nil, control_err
        end
        return candidate
      end
      if err.code ~= "EEXIST" then
        return nil, err
      end
    end
    return nil, { message = "could not allocate a unique aichatter session directory" }
  end

  function Shadow:_finish_activity(cancel)
    if cancel then
      self._cancels[cancel] = nil
    end
    self._active = self._active - 1
    self:_maybe_remove()
  end

  function Shadow:_copy(source, target, opts, callback)
    callback = once(callback)
    opts = vim.tbl_extend("force", {}, opts or {})
    local cancel = opts.cancel or { cancelled = false }
    opts.cancel = cancel
    self._cancels[cancel] = true
    self._active = self._active + 1
    local complete = once(function(err)
      callback(err)
      self:_finish_activity(cancel)
    end)
    local returned, thrown = pcall(fs.copy_tree, source, target, opts, complete)
    if not returned then
      complete(error_value(thrown))
    end
  end

  function Shadow:_write(target, bytes, mode, callback)
    callback = once(callback)
    self._active = self._active + 1
    local complete = once(function(err)
      callback(err)
      self:_finish_activity()
    end)
    local returned, thrown = pcall(fs.atomic_write, target, bytes, mode, complete)
    if not returned then
      complete(error_value(thrown))
    end
  end

  function Shadow:_maybe_remove()
    if not self._cleanup_requested or self._active ~= 0 or self._cleanup_started then
      return
    end
    self._cleanup_started = true
    local returned, thrown = pcall(
      fs.remove_tree_guarded,
      self.session_root,
      self._temp_parent,
      once(function(err)
        self._cleanup_error = err
        self._cleanup_done = true
        local callbacks = self._cleanup_callbacks
        self._cleanup_callbacks = {}
        for _, callback in ipairs(callbacks) do
          pcall(callback, err)
        end
      end)
    )
    if not returned then
      self._cleanup_error = error_value(thrown)
      self._cleanup_done = true
      local callbacks = self._cleanup_callbacks
      self._cleanup_callbacks = {}
      for _, callback in ipairs(callbacks) do
        pcall(callback, self._cleanup_error)
      end
    end
  end

  function Shadow:cleanup(callback)
    callback = callback or function() end
    if self._cleanup_done then
      pcall(callback, self._cleanup_error)
      return
    end
    self._cleanup_callbacks[#self._cleanup_callbacks + 1] = callback
    self._cleanup_requested = true
    for cancel in pairs(self._cancels) do
      cancel.cancelled = true
    end
    self:_maybe_remove()
  end

  function Shadow:_buffers(exclude)
    local ok, buffers = pcall(self._buffer_provider, self.project_root)
    if not ok then
      return nil, error_value(buffers)
    end
    if type(buffers) ~= "table" then
      return nil, { message = "buffer_provider must return a table" }
    end
    local selected = {}
    for _, buffer in ipairs(buffers) do
      if type(buffer) ~= "table" or type(buffer.path) ~= "string"
        or type(buffer.bytes) ~= "string" then
        return nil, { message = "buffer_provider returned an invalid buffer" }
      end
      local buffer_path = path.normalize(buffer.path)
      if buffer_path == self.project_root or not path.is_within(self.project_root, buffer_path) then
        return nil, { message = "buffer outside project root: " .. buffer_path }
      end
      local relative = path.relative(self.project_root, buffer_path)
      if not exclude[relative] then
        selected[#selected + 1] = {
          relative = relative,
          bytes = buffer.bytes,
          mode = buffer.mode or 420,
        }
      end
    end
    return selected
  end

  function Shadow:_overlay_buffers(exclude, callback)
    callback = once(callback)
    local buffers, err = self:_buffers(exclude or {})
    if not buffers then
      callback(err)
      return
    end
    local buffer_index = 1
    local destination_index = 1
    local destinations = { self.baseline_root, self.workspace_root }
    local advance
    advance = function(write_err)
      if write_err then
        callback(write_err)
        return
      end
      if self._cleanup_requested then
        callback({ code = "cancelled", message = "shadow work cancelled" })
        return
      end
      local buffer = buffers[buffer_index]
      if not buffer then
        callback()
        return
      end
      local destination = destinations[destination_index]
      destination_index = destination_index + 1
      if destination_index > #destinations then
        destination_index = 1
        buffer_index = buffer_index + 1
      end
      self:_write(destination .. "/" .. buffer.relative, buffer.bytes, buffer.mode, advance)
    end
    advance()
  end

  function Shadow:overlay_buffers(callback)
    self:_overlay_buffers({}, callback or function() end)
  end

  local function normalized_exclusions(project_root, exclude_paths)
    local result = { [".git"] = true }
    for value, excluded in pairs(exclude_paths or {}) do
      if excluded then
        local relative = value
        if value:sub(1, 1) == "/" then
          local absolute = path.normalize(value)
          if path.is_within(project_root, absolute) and absolute ~= project_root then
            relative = path.relative(project_root, absolute)
          else
            relative = nil
          end
        else
          relative = value:gsub("^%./", "")
        end
        if relative and relative ~= "" and relative ~= "."
          and relative ~= ".." and relative:sub(1, 3) ~= "../" then
          result[relative] = true
        end
      end
    end
    return result
  end

  function Shadow:sync_live(exclude_paths, callback)
    callback = once(callback or function() end)
    if self._cleanup_requested then
      callback({ code = "cancelled", message = "shadow work cancelled" })
      return
    end
    local exclude = normalized_exclusions(self.project_root, exclude_paths)
    self:_copy(self.project_root, self.workspace_root, {
      exclude = exclude,
      overlay = true,
    }, function(workspace_err)
      if workspace_err then
        callback(workspace_err)
        return
      end
      if self._cleanup_requested then
        callback({ code = "cancelled", message = "shadow work cancelled" })
        return
      end
      self:_copy(self.project_root, self.baseline_root, {
        exclude = exclude,
        overlay = true,
      }, function(baseline_err)
        if baseline_err then
          callback(baseline_err)
          return
        end
        self:_overlay_buffers(exclude, callback)
      end)
    end)
  end

  local function run_command(run, argv, callback)
    callback = once(callback)
    local ok, result = pcall(run, argv, callback)
    if not ok then
      callback(error_value(result))
    end
  end

  function Shadow.create(opts, callback)
    opts = opts or {}
    callback = once(callback or function() end)
    local root = path.project_root(assert(opts.root, "root is required"))
    local temp_parent = path.normalize(assert(opts.temp_parent, "temp_parent is required"))
    local session_root, session_err = create_session_root(temp_parent)
    if not session_root then
      callback(session_err)
      return
    end
    local self = setmetatable({
      session_root = session_root,
      baseline_root = session_root .. "/control/baseline",
      workspace_root = session_root .. "/workspace",
      project_root = root,
      _temp_parent = temp_parent,
      _buffer_provider = opts.buffer_provider or default_buffer_provider,
      _active = 0,
      _cancels = {},
      _cleanup_callbacks = {},
      _cleanup_requested = false,
      _cleanup_started = false,
      _cleanup_done = false,
    }, Shadow)
    local run = opts.run or dependencies.run or default_run

    local function fail(err)
      self:cleanup(function()
        callback(err)
      end)
    end

    local function overlay_live_then_baseline()
      self:_copy(root, self.workspace_root, {
        exclude = { [".git"] = true },
        overlay = true,
      }, function(overlay_err)
        if overlay_err then
          fail(overlay_err)
          return
        end
        self:_copy(self.workspace_root, self.baseline_root, {
          exclude = { [".git"] = true },
        }, function(baseline_err)
          if baseline_err then
            fail(baseline_err)
            return
          end
          self:_overlay_buffers({}, function(buffer_err)
            if buffer_err then
              fail(buffer_err)
            else
              callback(nil, self)
            end
          end)
        end)
      end)
    end

    local detect_argv = { "git", "-C", root, "rev-parse", "--is-inside-work-tree" }
    run_command(run, detect_argv, function(detect_err, detect_result)
      if detect_err then
        fail(command_error("git detection", detect_argv, detect_err))
        return
      end
      local is_git = detect_result and detect_result.code == 0
        and vim.trim(detect_result.stdout or "") == "true"
      if not is_git then
        self:_copy(root, self.workspace_root, {
          exclude = { [".git"] = true },
        }, function(copy_err)
          if copy_err then
            fail(copy_err)
          else
            self:_copy(self.workspace_root, self.baseline_root, {
              exclude = { [".git"] = true },
            }, function(baseline_err)
              if baseline_err then
                fail(baseline_err)
                return
              end
              self:_overlay_buffers({}, function(buffer_err)
                if buffer_err then
                  fail(buffer_err)
                else
                  callback(nil, self)
                end
              end)
            end)
          end
        end)
        return
      end

      local clone_argv = {
        "git", "clone", "--local", "--no-hardlinks", "--", root, self.workspace_root,
      }
      run_command(run, clone_argv, function(clone_err, clone_result)
        if clone_err then
          fail(command_error("git clone", clone_argv, clone_err))
        elseif not clone_result or clone_result.code ~= 0 then
          fail(command_error("git clone", clone_argv, nil, clone_result))
        else
          overlay_live_then_baseline()
        end
      end)
    end)
  end

  Shadow._new = new
  return Shadow
end

return new()
