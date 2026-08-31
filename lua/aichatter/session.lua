local Auth = require("aichatter.auth")
local Context = require("aichatter.context")
local Review = require("aichatter.review")
local Shadow = require("aichatter.shadow")
local Transport = require("aichatter.transport")
local path = require("aichatter.path")

local Session = {}
Session.__index = Session

local UPGRADE_DIAGNOSTIC =
  "Codex CLI is too old for aichatter.nvim; upgrade Codex and retry."

local allowed = {
  closed = { starting = true },
  starting = { auth_required = true, idle = true, failed = true, closing = true },
  auth_required = { idle = true, failed = true, closing = true },
  idle = { running = true, closing = true },
  running = {
    waiting_for_command_approval = true,
    idle = true,
    reviewable = true,
    failed = true,
    closing = true,
  },
  waiting_for_command_approval = { running = true, failed = true, closing = true },
  reviewable = { running = true, idle = true, closing = true },
  failed = { starting = true, reviewable = true, closing = true },
  closing = { closed = true },
}

local function noop() end

local function once(callback)
  local called = false
  return function(...)
    if called then return end
    called = true
    return callback(...)
  end
end

local function public_callback(callback)
  callback = callback or noop
  return once(function(...)
    pcall(callback, ...)
  end)
end

local function error_value(err)
  if type(err) == "table" then return err end
  return { message = tostring(err) }
end

local function state_error(message)
  return { code = "invalid_state", message = message }
end

local function unsupported_v2(err)
  local rendered = string.lower(vim.inspect(err or {}))
  local names_required_field = rendered:find("ephemeral", 1, true)
    or rendered:find("readonlyaccess", 1, true)
  if not names_required_field then return false end
  return rendered:find("unsupported", 1, true) ~= nil
    or rendered:find("not supported", 1, true) ~= nil
    or rendered:find("unknown", 1, true) ~= nil
    or rendered:find("unrecognized", 1, true) ~= nil
    or rendered:find("unexpected", 1, true) ~= nil
end

local function default_review_factory(shadow)
  local Live = require("aichatter.live")
  return Review.new({
    baseline_root = shadow.baseline_root,
    workspace_root = shadow.workspace_root,
    live = Live.new(shadow.project_root),
  })
end

local function default_temp_parent()
  local uv = vim.uv or vim.loop
  return assert(uv.os_tmpdir(), "could not locate temporary directory")
end

function Session.new(deps)
  deps = deps or {}
  local transport = deps.transport or Transport.new()
  local root = deps.root or assert((vim.uv or vim.loop).cwd())
  local self = setmetatable({
    state = "closed",
    transport = transport,
    auth = deps.auth or Auth.new(transport),
    shadow = deps.shadow,
    review = deps.review,
    context = deps.context,
    root = root,
    temp_parent = deps.temp_parent or default_temp_parent(),
    create_shadow = deps.create_shadow or Shadow.create,
    review_factory = deps.review_factory or default_review_factory,
    emit = deps.emit or noop,
    thread_id = nil,
    turn_id = nil,
    transcript = deps.transcript or {},
    pending_commands = {},
    handlers = {},
    restart_attempted = false,
    _sending = false,
    _close_callbacks = nil,
    _assistant_entry = nil,
  }, Session)
  self:_register_handlers()
  return self
end

function Session:_emit(name, value)
  local ok, err = pcall(self.emit, name, value)
  if not ok then self.last_emit_error = error_value(err) end
end

function Session:_transition(next_state)
  assert(allowed[self.state] and allowed[self.state][next_state],
    ("invalid session transition %s -> %s"):format(self.state, next_state))
  self.state = next_state
  self:_emit("state", next_state)
end

function Session:_listen(method, listener)
  self.transport:on(method, listener)
  self.handlers[#self.handlers + 1] = { method = method, listener = listener }
end

function Session:_unregister_handlers()
  for _, handler in ipairs(self.handlers) do
    self.transport:off(handler.method, handler.listener)
  end
  self.handlers = {}
end

function Session:_matches_active(params)
  if not self.turn_id then return false end
  if params and params.threadId and params.threadId ~= self.thread_id then return false end
  if params and params.turnId and params.turnId ~= self.turn_id then return false end
  return true
end

function Session:_record_error(err)
  local normalized = error_value(err)
  self.transcript[#self.transcript + 1] = { type = "error", error = normalized }
  self:_emit("error", normalized)
end

function Session:_fail(err, callback)
  err = error_value(err)
  if self.state ~= "failed" then
    if allowed[self.state] and allowed[self.state].failed then
      self:_transition("failed")
    end
  end
  self:_record_error(err)
  if callback then callback(err) end
end

function Session:_required_v2_error(err)
  if unsupported_v2(err) then return { message = UPGRADE_DIAGNOSTIC, cause = err } end
  return error_value(err)
end

function Session:_on_delta(params)
  if not self:_matches_active(params) then return end
  if not self._assistant_entry then
    self._assistant_entry = { type = "assistant", text = "" }
    self.transcript[#self.transcript + 1] = self._assistant_entry
  end
  self._assistant_entry.text = self._assistant_entry.text .. (params.delta or "")
  self:_emit("item/agentMessage/delta", params)
end

function Session:_on_item(method, status, params)
  if not self:_matches_active(params) then return end
  self.transcript[#self.transcript + 1] = {
    type = "activity",
    status = status,
    item = params and params.item or params,
  }
  self:_emit(method, params)
end

function Session:_on_protocol_error(params)
  local err = params and (params.error or params) or { message = "app-server error" }
  self:_record_error(err)
end

function Session:_on_file_approval(params, request_id)
  if not request_id or not self.shadow or not self.shadow.workspace_root or not self.thread_id then
    return
  end
  if params and params.threadId and params.threadId ~= self.thread_id then return end
  local grant_root = params and params.grantRoot
  if type(grant_root) == "string" then
    local ok, normalized = pcall(path.normalize, grant_root, self.shadow.workspace_root)
    if not ok or not path.is_within(self.shadow.workspace_root, normalized) then return end
  elseif grant_root ~= nil and grant_root ~= vim.NIL then
    return
  end
  self.transport:respond(request_id, { decision = "acceptForSession" })
  self:_emit("item/fileChange/requestApproval", {
    requestId = request_id,
    request = params,
    decision = "acceptForSession",
  })
end

function Session:_on_command_approval(params, request_id)
  if not request_id or self.state ~= "running" or not self:_matches_active(params) then return end
  local entry = {
    type = "approval",
    request_id = request_id,
    request = params,
    status = "pending",
  }
  self.pending_commands[request_id] = { params = params, entry = entry }
  self.transcript[#self.transcript + 1] = entry
  self:_transition("waiting_for_command_approval")
  self:_emit("item/commandExecution/requestApproval", {
    requestId = request_id,
    request = params,
  })
end

function Session:_on_turn_completed(params)
  local turn = params and params.turn or {}
  if not self.turn_id or turn.id ~= self.turn_id then return end
  self.turn_id = nil
  self._assistant_entry = nil
  if self.state == "waiting_for_command_approval" then
    self.pending_commands = {}
    self:_transition("running")
  end
  if self.state ~= "running" then return end
  self:_emit("turn/completed", params)
  local completed = once(function(err)
    if self.state == "closing" or self.state == "closed" then return end
    if err then
      self:_fail(err)
      return
    end
    local files = self.review:files()
    self:_transition(#files > 0 and "reviewable" or "idle")
  end)
  local ok, thrown = pcall(self.review.refresh, self.review, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:_on_exit(result)
  if self.state == "closing" or self.state == "closed" then return end
  local err = {
    message = "app-server exited unexpectedly",
    code = result and result.code,
    signal = result and result.signal,
  }
  self.turn_id = nil
  self._assistant_entry = nil
  self.pending_commands = {}
  self._sending = false
  if self.state ~= "failed" and allowed[self.state] and allowed[self.state].failed then
    self:_transition("failed")
  end
  self:_record_error(err)
  if self.restart_attempted or self.state ~= "failed" then return end
  self.restart_attempted = true
  self:_transition("starting")
  self:_emit("restart", { attempt = 1 })
  local restarted = once(function(start_err)
    if start_err then
      self:_fail(start_err)
      return
    end
    self:_start_thread(nil, true)
  end)
  local ok, thrown = pcall(self.transport.start, self.transport, restarted)
  if not ok then restarted(error_value(thrown)) end
end

function Session:_register_handlers()
  self:_listen("item/agentMessage/delta", function(params) self:_on_delta(params) end)
  self:_listen("item/started", function(params) self:_on_item("item/started", "started", params) end)
  self:_listen("item/completed", function(params) self:_on_item("item/completed", "completed", params) end)
  self:_listen("turn/completed", function(params) self:_on_turn_completed(params) end)
  self:_listen("item/fileChange/requestApproval",
    function(params, id) self:_on_file_approval(params, id) end)
  self:_listen("item/commandExecution/requestApproval",
    function(params, id) self:_on_command_approval(params, id) end)
  self:_listen("error", function(params) self:_on_protocol_error(params) end)
  self:_listen("turn/error", function(params) self:_on_protocol_error(params) end)
  self:_listen("exit", function(result) self:_on_exit(result) end)
end

function Session:_start_thread(callback, restarting)
  callback = callback and once(callback) or noop
  local params = {
    ephemeral = true,
    cwd = self.shadow.workspace_root,
    approvalPolicy = "untrusted",
    sandbox = "workspaceWrite",
  }
  local completed = once(function(err, result)
    if err then
      self:_fail(self:_required_v2_error(err), callback)
      return
    end
    local thread_id = result and result.thread and result.thread.id
    if type(thread_id) ~= "string" or thread_id == "" then
      self:_fail({ message = "thread/start returned no thread id" }, callback)
      return
    end
    self.thread_id = thread_id
    self:_transition("idle")
    if restarting then self:_emit("restarted", { threadId = thread_id }) end
    callback(nil, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport, "thread/start", params, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:_ensure_workspace(callback)
  callback = once(callback)
  local function start_thread()
    if not self.review then
      local ok, value = pcall(self.review_factory, self.shadow)
      if not ok then callback(error_value(value)); return end
      self.review = value
    end
    if not self.context then
      self.context = Context.new(self.shadow.project_root or self.root)
    end
    self:_start_thread(callback)
  end
  if self.shadow then
    start_thread()
    return
  end
  local created = once(function(err, shadow)
    if err then callback(err); return end
    if not shadow then callback({ message = "shadow creation returned no workspace" }); return end
    self.shadow = shadow
    start_thread()
  end)
  local ok, thrown = pcall(self.create_shadow, {
    root = self.root,
    temp_parent = self.temp_parent,
  }, created)
  if not ok then created(error_value(thrown)) end
end

function Session:start(callback)
  callback = public_callback(callback)
  if self.state ~= "closed" and self.state ~= "failed" then
    callback(state_error("session can only start while closed or failed"))
    return
  end
  self:_transition("starting")
  local started = once(function(err)
    if err then self:_fail(err, callback); return end
    local checked = once(function(auth_err, account)
      if auth_err then self:_fail(auth_err, callback); return end
      if not account or not account.authenticated then
        self:_transition("auth_required")
        callback(nil, account)
        return
      end
      self:_ensure_workspace(function(workspace_err, result)
        if workspace_err and self.state ~= "failed" then self:_fail(workspace_err, callback)
        elseif workspace_err then callback(workspace_err)
        else callback(nil, result) end
      end)
    end)
    local ok, thrown = pcall(self.auth.check, self.auth, checked)
    if not ok then checked(error_value(thrown)) end
  end)
  local ok, thrown = pcall(self.transport.start, self.transport, started)
  if not ok then started(error_value(thrown)) end
end

function Session:login(callback)
  callback = public_callback(callback)
  if self.state ~= "auth_required" then
    callback(state_error("login requires an auth_required session"))
    return
  end
  local logged_in = once(function(err, result)
    if err then
      self:_record_error(err)
      callback(err)
      return
    end
    self:_ensure_workspace(function(workspace_err, thread)
      if workspace_err and self.state ~= "failed" then self:_fail(workspace_err, callback)
      elseif workspace_err then callback(workspace_err)
      else callback(nil, thread or result) end
    end)
  end)
  local ok, thrown = pcall(self.auth.login, self.auth, logged_in)
  if not ok then logged_in(error_value(thrown)) end
end

function Session:_turn_policy()
  return {
    type = "workspaceWrite",
    writableRoots = { self.shadow.workspace_root },
    readOnlyAccess = {
      type = "restricted",
      includePlatformDefaults = true,
      readableRoots = { self.shadow.workspace_root },
    },
    networkAccess = false,
  }
end

function Session:send(text, callback)
  callback = public_callback(callback)
  if (self.state ~= "idle" and self.state ~= "reviewable") or self._sending then
    callback(state_error("send requires an idle or reviewable session"))
    return
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    callback({ code = "invalid_prompt", message = "prompt must not be blank" })
    return
  end
  if not self.thread_id or not self.shadow or not self.review or not self.context then
    callback(state_error("session is not initialized"))
    return
  end
  self._sending = true
  local synced = once(function(sync_err)
    self._sending = false
    if self.state == "closing" or self.state == "closed" then
      callback(state_error("session closed while synchronizing"))
      return
    end
    if sync_err then
      sync_err = error_value(sync_err)
      if sync_err.code == "conflict" then self:_emit("conflict", sync_err) end
      callback(sync_err)
      return
    end
    local ok_inputs, inputs = pcall(self.context.inputs, self.context, text)
    if not ok_inputs then callback(error_value(inputs)); return end
    self:_transition("running")
    self._assistant_entry = nil
    local completed = once(function(err, result)
      if err then
        self:_fail(self:_required_v2_error(err), callback)
        return
      end
      local turn_id = result and result.turn and result.turn.id
      if type(turn_id) ~= "string" or turn_id == "" then
        self:_fail({ message = "turn/start returned no turn id" }, callback)
        return
      end
      self.turn_id = turn_id
      self.context:clear()
      local entry = { type = "user", text = text, input = inputs }
      self.transcript[#self.transcript + 1] = entry
      self:_emit("user", entry)
      callback(nil, result)
    end)
    local params = {
      threadId = self.thread_id,
      input = inputs,
      sandboxPolicy = self:_turn_policy(),
    }
    local requested, thrown = pcall(
      self.transport.request,
      self.transport,
      "turn/start",
      params,
      completed
    )
    if not requested then completed(error_value(thrown)) end
  end)
  local ok, thrown = pcall(self.review.sync_live, self.review, synced)
  if not ok then synced(error_value(thrown)) end
end

function Session:steer(text, callback)
  callback = public_callback(callback)
  if self.state ~= "running" or not self.turn_id then
    callback(state_error("steer requires an active turn"))
    return
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    callback({ code = "invalid_prompt", message = "steer text must not be blank" })
    return
  end
  local completed = once(function(err, result)
    if err then self:_record_error(err) end
    callback(err, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport, "turn/steer", {
    threadId = self.thread_id,
    expectedTurnId = self.turn_id,
    input = { { type = "text", text = text } },
  }, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:approve_command(request_id, decision)
  local pending = self.pending_commands[request_id]
  if not pending then return false, { message = "unknown command approval request" } end
  if type(decision) ~= "string" or decision == "" then
    return false, { message = "command approval decision is required" }
  end
  local ok, err = self.transport:respond(request_id, { decision = decision })
  if not ok then return false, err end
  pending.entry.status = "decided"
  pending.entry.decision = decision
  self.pending_commands[request_id] = nil
  if self.state == "waiting_for_command_approval" then self:_transition("running") end
  return true
end

function Session:cancel(callback)
  callback = public_callback(callback)
  if (self.state ~= "running" and self.state ~= "waiting_for_command_approval")
    or not self.turn_id then
    callback(state_error("cancel requires an active turn"))
    return
  end
  local completed = once(function(err, result)
    if err then self:_record_error(err) end
    callback(err, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport, "turn/interrupt", {
    threadId = self.thread_id,
    turnId = self.turn_id,
  }, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:close(callback)
  callback = public_callback(callback)
  if self.state == "closed" then callback(); return end
  if self.state == "closing" then
    self._close_callbacks[#self._close_callbacks + 1] = callback
    return
  end
  self._close_callbacks = { callback }
  local active_turn = self.turn_id
  self:_transition("closing")
  self:_unregister_handlers()
  self._sending = false
  self.turn_id = nil
  self.pending_commands = {}
  if active_turn then
    pcall(self.transport.request, self.transport, "turn/interrupt", {
      threadId = self.thread_id,
      turnId = active_turn,
    }, noop)
  end
  local remaining = 2
  local first_error
  local function finished(err)
    if err and not first_error then first_error = error_value(err) end
    remaining = remaining - 1
    if remaining ~= 0 then return end
    self:_transition("closed")
    local callbacks = self._close_callbacks
    self._close_callbacks = nil
    for _, close_callback in ipairs(callbacks) do close_callback(first_error) end
  end
  local stopped = once(finished)
  local ok_stop, stop_err = pcall(self.transport.stop, self.transport, stopped)
  if not ok_stop then stopped(error_value(stop_err)) end
  local cleaned = once(finished)
  if self.shadow and self.shadow.cleanup then
    local ok_cleanup, cleanup_err = pcall(self.shadow.cleanup, self.shadow, cleaned)
    if not ok_cleanup then cleaned(error_value(cleanup_err)) end
  else
    cleaned()
  end
end

return Session
