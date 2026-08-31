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
  }, Transport)

  self.parser = jsonl.new(function(message)
    self:_dispatch(message)
  end, function(err, line)
    self.last_error = { message = err, line = line }
  end)

  return self
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

function Transport:_emit(method, params, id)
  local listeners = self.listeners[method]
  if not listeners then
    return
  end

  for _, listener in ipairs(listeners) do
    listener(params, id)
  end
end

function Transport:_dispatch(message)
  if message.id and not message.method then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    if callback then
      callback(message.error, message.result)
    end
    return
  end

  if message.id and message.method then
    self:_emit(message.method, message.params, message.id)
    return
  end

  if message.method then
    self:_emit(message.method, message.params)
  end
end

function Transport:_reject_pending(err)
  local pending = self.pending
  self.pending = {}
  for _, callback in pairs(pending) do
    callback(err)
  end
end

function Transport:_on_exit(result)
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

  local ok, process_or_err = pcall(self.launcher, self.cmd, {
    stdin = true,
    text = true,
    stdout = function(_, chunk)
      self:_schedule(function()
        if chunk then
          self.parser:push(chunk)
        end
      end)
    end,
    stderr = function(_, chunk)
      self:_schedule(function()
        self.stderr = self.stderr .. (chunk or "")
      end)
    end,
  }, function(result)
    self:_schedule(function()
      self:_on_exit(result)
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

  if not self.process or self.process:is_closing() then
    self:_schedule(function()
      self:_on_exit({})
    end)
    return
  end

  self.process:write(nil)
  self.defer(function()
    if self.process and not self.process:is_closing() then
      self.process:kill("sigterm")
    end
  end, 100)
end

return Transport
