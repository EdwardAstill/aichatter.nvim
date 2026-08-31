local jsonl = require("aichatter.jsonl")

local Transport = {}
Transport.__index = Transport

local function stopped_error()
  return { message = "transport stopped" }
end

function Transport.new(opts)
  opts = opts or {}

  local self = setmetatable({
    cmd = opts.cmd or require("aichatter.config").get().codex_cmd,
    next_id = 1,
    pending = {},
    listeners = {},
    stderr = "",
    launcher = opts.launcher or vim.system,
    scheduler = opts.scheduler or vim.schedule,
    defer = opts.defer or vim.defer_fn,
    generation = 0,
  }, Transport)

  self:_reset_parser()

  return self
end

function Transport:_reset_parser()
  self.parser = jsonl.new(function(message)
    self:_dispatch(message)
  end, function(err, line)
    self:_emit_diagnostic("malformed_json", "malformed JSON from app-server", {
      detail = err,
      line = line,
    })
  end)
end

function Transport:_schedule(callback)
  self.scheduler(callback)
end

function Transport:_write(message)
  if not self.process or self.process:is_closing() then
    return false, stopped_error()
  end

  self.process:write(vim.json.encode(message) .. "\n")
  return true
end

function Transport:_emit_diagnostic(code, message, extra)
  local diagnostic = vim.tbl_extend("force", {
    code = code,
    message = message,
  }, extra or {})
  self.last_error = diagnostic
  local listeners = self.listeners.error
  if not listeners then return end
  for _, listener in ipairs(vim.list_slice(listeners)) do
    local ok, err = pcall(listener, diagnostic)
    if not ok then
      self.last_emit_error = {
        code = "listener_error",
        method = "error",
        message = tostring(err),
      }
    end
  end
end

function Transport:_emit(method, params, id)
  local listeners = self.listeners[method]
  if not listeners then
    return false
  end

  local delivered = false
  for _, listener in ipairs(vim.list_slice(listeners)) do
    delivered = true
    local ok, err = pcall(listener, params, id)
    if not ok then
      self:_emit_diagnostic("listener_error",
        "listener for " .. tostring(method) .. " failed: " .. tostring(err), {
          method = method,
          detail = tostring(err),
        })
    end
  end
  return delivered
end

function Transport:_dispatch(message)
  if message.id and not message.method then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    if callback then
      callback(message.error, message.result)
    else
      self:_emit_diagnostic("unknown_response",
        "received response for an unknown request", {
          id = message.id,
          error = message.error,
          result = message.result,
        })
    end
    return
  end

  if message.id and message.method then
    if not self:_emit(message.method, message.params, message.id) then
      self:_emit_diagnostic("unknown_notification",
        "received request for an unknown method", {
          id = message.id,
          method = message.method,
          params = message.params,
        })
    end
    return
  end

  if message.method then
    if not self:_emit(message.method, message.params) then
      self:_emit_diagnostic("unknown_notification",
        "received notification for an unknown method", {
          method = message.method,
          params = message.params,
        })
    end
    return
  end

  self:_emit_diagnostic("unknown_message", "received unrecognized app-server frame", {
    frame = message,
  })
end

function Transport:_reject_pending(err)
  local pending = self.pending
  self.pending = {}
  for _, callback in pairs(pending) do
    callback(err)
  end
end

function Transport:_on_exit(result, generation)
  if generation and generation ~= self.generation then
    return
  end
  self.process = nil
  self.exited = true
  self.parser:finish()

  if not self.stopped then
    self:_reject_pending({
      message = "app-server exited",
      code = result.code,
      signal = result.signal,
      stderr = self.stderr,
    })
  end

  self:_emit("exit", result)

  if self.stop_callback then
    local callback = self.stop_callback
    self.stop_callback = nil
    callback()
  end
end

function Transport:start(callback)
  callback = callback or function() end
  if self.process then
    self:_schedule(function()
      callback({ message = "transport already started" })
    end)
    return
  end

  self.generation = self.generation + 1
  local generation = self.generation
  self.stopped = false
  self.exited = false
  self.stderr = ""
  self:_reset_parser()

  local ok, process_or_err = pcall(self.launcher, self.cmd, {
    stdin = true,
    text = true,
    stdout = function(_, chunk)
      self:_schedule(function()
        if generation == self.generation and chunk then
          self.parser:push(chunk)
        end
      end)
    end,
    stderr = function(_, chunk)
      self:_schedule(function()
        if generation == self.generation then
          self.stderr = self.stderr .. (chunk or "")
        end
      end)
    end,
  }, function(result)
    self:_schedule(function()
      self:_on_exit(result, generation)
    end)
  end)

  if not ok then
    self:_schedule(function()
      callback({ message = process_or_err })
    end)
    return
  end

  self.process = process_or_err
  self:request("initialize", {
    clientInfo = { name = "aichatter.nvim", version = "0.1.0" },
    capabilities = { experimentalApi = true },
  }, function(err)
    if err then
      callback(err)
      return
    end

    self:notify("initialized", {})
    callback(nil)
  end)
end

function Transport:request(method, params, callback)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = callback or function() end

  local ok, err = self:_write({ id = id, method = method, params = params })
  if not ok then
    local pending = self.pending[id]
    self.pending[id] = nil
    self:_schedule(function()
      pending(err)
    end)
  end

  return id
end

function Transport:notify(method, params)
  return self:_write({ method = method, params = params })
end

function Transport:respond(id, result, err)
  return self:_write({ id = id, result = result, error = err })
end

function Transport:on(method, listener)
  local listeners = self.listeners[method]
  if not listeners then
    listeners = {}
    self.listeners[method] = listeners
  end
  listeners[#listeners + 1] = listener
end

function Transport:off(method, listener)
  local listeners = self.listeners[method]
  if not listeners then
    return
  end

  for index, current in ipairs(listeners) do
    if current == listener then
      table.remove(listeners, index)
      return
    end
  end
end

function Transport:stop(callback)
  callback = callback or function() end
  if self.stopped then
    self:_schedule(callback)
    return
  end

  self.stopped = true
  self.stop_callback = callback
  self:_schedule(function()
    self:_reject_pending(stopped_error())
  end)

  if not self.process then
    self:_schedule(function()
      local stop_callback = self.stop_callback
      self.stop_callback = nil
      if stop_callback then stop_callback() end
    end)
    return
  end

  if self.process:is_closing() then return end

  self.process:write(nil)
  self.defer(function()
    if self.process and not self.process:is_closing() then
      self.process:kill("sigterm")
    end
  end, 100)
end

return Transport
