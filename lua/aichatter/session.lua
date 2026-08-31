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
  closed = { starting = true, closing = true },
  starting = {
    auth_required = true,
    idle = true,
    reviewable = true,
    failed = true,
    closing = true,
  },
  auth_required = { idle = true, failed = true, closing = true },
  idle = { running = true, reviewable = true, failed = true, closing = true },
  running = {
    waiting_for_command_approval = true,
    idle = true,
    reviewable = true,
    failed = true,
    closing = true,
  },
  waiting_for_command_approval = { running = true, failed = true, closing = true },
  reviewable = { running = true, idle = true, failed = true, closing = true },
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

local function normalized_error_text(value)
  return " " .. string.lower(value):gsub("[^%w_%-]+", " ") .. " "
end

local function has_error_phrase(value, phrase)
  return normalized_error_text(value):find(" " .. phrase .. " ", 1, true) ~= nil
end

local function has_error_code(value, field)
  local code = string.lower(value):gsub("[^%w]+", "_")
    :gsub("^_+", ""):gsub("_+$", "")
  for _, relationship in ipairs({
    "unsupported", "unknown", "unrecognized", "unexpected", "invalid",
  }) do
    if code == relationship .. "_" .. field then return true end
    for _, subject in ipairs({ "field", "parameter", "property" }) do
      if code == relationship .. "_" .. subject .. "_" .. field then return true end
    end
  end
  for _, subject in ipairs({ "field", "parameter", "property" }) do
    if code == "not_supported_" .. subject .. "_" .. field then return true end
  end
  return false
end

local function unsupported_v2(err)
  if type(err) ~= "table" or type(err.message) ~= "string" then return false end
  for _, field in ipairs({ "ephemeral", "readonlyaccess" }) do
    if type(err.code) == "string" and has_error_code(err.code, field) then return true end
    for _, phrase in ipairs({
      "unsupported " .. field,
      "unsupported field " .. field,
      "unsupported parameter " .. field,
      "unsupported property " .. field,
      "invalid field " .. field,
      "invalid parameter " .. field,
      "invalid property " .. field,
      field .. " is unsupported",
      field .. " is not supported",
      field .. " is invalid",
      field .. " field is unsupported",
      field .. " field is not supported",
      "field " .. field .. " is unsupported",
      "field " .. field .. " is not supported",
      "unknown field " .. field,
      "unknown parameter " .. field,
      "unknown property " .. field,
      "unrecognized field " .. field,
      "unrecognized parameter " .. field,
      "unexpected field " .. field,
      "unexpected parameter " .. field,
    }) do
      if has_error_phrase(err.message, phrase) then return true end
    end
  end
  return false
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

local function cleanup_shadow(shadow)
  if not shadow or type(shadow.cleanup) ~= "function" then return end
  pcall(shadow.cleanup, shadow, noop)
end

local function no_follow_grant(shadow, value)
  if type(shadow.validate_grant_root) == "function" then
    local ok, accepted, detail = pcall(shadow.validate_grant_root, shadow, value)
    return ok and accepted == true, ok and detail or accepted
  end
  local root = shadow.workspace_root
  if type(root) ~= "string" then return false end
  local grant = value
  if grant == nil or grant == vim.NIL then grant = root end
  if type(grant) ~= "string" then return false end
  local ok, absolute = pcall(path.normalize, grant, root)
  if not ok or (absolute ~= root and not path.is_within(root, absolute)) then return false end
  local uv = vim.uv or vim.loop
  local current = root
  local root_stat = uv.fs_lstat(current)
  if not root_stat or root_stat.type ~= "directory" then return false end
  local relative = path.relative(root, absolute)
  if relative ~= "." then
    for component in relative:gmatch("[^/]+") do
      current = current .. "/" .. component
      local stat = uv.fs_lstat(current)
      if not stat or stat.type ~= "directory" then return false end
    end
  end
  return true, absolute
end

function Session.new(deps)
  deps = deps or {}
  local transport = deps.transport or Transport.new()
  local root = deps.root or path.project_root(assert((vim.uv or vim.loop).cwd()))
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
    operations = {},
    generation = 0,
    restart_attempted = false,
    started = false,
    disposed = false,
    _sending = false,
    _close_callbacks = nil,
    _assistant_entry = nil,
    _pending_turn = nil,
    _expected_exit = false,
    _settling = false,
    _review_queue = {},
    _review_active = nil,
    _review_waiters = {},
    _review_sequence = 0,
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

function Session:_new_operation(callback)
  local operation = {
    callback = public_callback(callback),
    generation = self.generation,
    finished = false,
  }
  self.operations[operation] = true
  return operation
end

function Session:_finish_operation(operation, ...)
  if not operation or operation.finished then return end
  operation.finished = true
  self.operations[operation] = nil
  operation.callback(...)
end

function Session:_operation_current(operation)
  return operation and not operation.finished and not self.disposed
    and operation.generation == self.generation
end

function Session:_generation_current(generation)
  return not self.disposed and generation == self.generation
end

function Session:_reject_reentry(callback)
  if not self._settling then return false end
  callback(state_error("session lifecycle transition in progress"))
  return true
end

local review_methods = {
  refresh = true,
  accept_hunk = true,
  reject_hunk = true,
  edit_candidate = true,
  accept_file = true,
  reject_file = true,
}

function Session:_notify_review_idle()
  if self._review_active or #self._review_queue > 0 then return end
  local waiters = self._review_waiters
  self._review_waiters = {}
  for _, waiter in ipairs(waiters) do pcall(waiter) end
end

function Session:_when_review_idle(callback)
  if not self._review_active and #self._review_queue == 0 then
    callback()
  else
    self._review_waiters[#self._review_waiters + 1] = callback
  end
end

function Session:_cancel_review_queue(err)
  local queued = self._review_queue
  self._review_queue = {}
  for _, action in ipairs(queued) do action.callback(error_value(err)) end
  self:_notify_review_idle()
end

function Session:_reconcile_review_state()
  if self.disposed or (self.state ~= "idle" and self.state ~= "reviewable") then return nil end
  local ok, files = pcall(self.review.files, self.review)
  if not ok then return error_value(files) end
  files = files or {}
  if #files == 0 and self.state == "reviewable" then
    self:_transition("idle")
  elseif #files > 0 and self.state == "idle" then
    self:_transition("reviewable")
  end
  self:_emit("review", files)
  return nil
end

function Session:_start_review_action()
  if self._review_active or self.disposed then
    self:_notify_review_idle()
    return
  end
  local action = table.remove(self._review_queue, 1)
  if not action then
    self:_notify_review_idle()
    return
  end
  self._review_active = action
  local completed = once(function(err, ...)
    if self._review_active ~= action then return end
    self._review_active = nil
    if not err and #self._review_queue == 0 then err = self:_reconcile_review_state() end
    action.callback(err, ...)
    if self.disposed then
      self:_cancel_review_queue({ code = "closing", message = "session closing" })
    else
      self:_start_review_action()
    end
    self:_notify_review_idle()
  end)
  local method = self.review and self.review[action.method]
  if type(method) ~= "function" then
    completed({ code = "unsupported", message = "review action is unavailable: " .. action.method })
    return
  end
  local args = vim.list_slice(action.args)
  args[#args + 1] = completed
  local ok, thrown = pcall(method, self.review, unpack(args))
  if not ok then completed(error_value(thrown)) end
end

function Session:review_action(method, ...)
  local args = { ... }
  local callback = type(args[#args]) == "function" and table.remove(args) or nil
  callback = public_callback(callback)
  local function reject(err)
    callback(err)
    return false, err
  end
  if self:_reject_reentry(callback) then return false end
  if self.disposed then return reject(state_error("session is disposed")) end
  if not review_methods[method] then
    return reject({ code = "unsupported", message = "unknown review action: " .. tostring(method) })
  end
  if (self.state ~= "idle" and self.state ~= "reviewable") or self._sending then
    return reject(state_error("review actions require an idle or reviewable session"))
  end
  if not self.review then return reject(state_error("session review is not initialized")) end
  self._review_sequence = self._review_sequence + 1
  self._review_queue[#self._review_queue + 1] = {
    id = self._review_sequence,
    method = method,
    args = args,
    callback = callback,
  }
  self:_start_review_action()
  return true
end

function Session:_invalidate_operations()
  self.generation = self.generation + 1
  self._sending = false
  self._pending_turn = nil
  local pending = {}
  for operation in pairs(self.operations) do
    pending[#pending + 1] = operation
    self.operations[operation] = nil
  end
  return pending
end

function Session:_settle_operations(pending, err)
  err = error_value(err)
  for _, operation in ipairs(pending) do
    self:_finish_operation(operation, err)
  end
end

function Session:_record_error(err)
  local normalized = error_value(err)
  self.transcript[#self.transcript + 1] = { type = "error", error = normalized }
  self:_emit("error", normalized)
end

function Session:_fail(err, operation)
  err = error_value(err)
  if self.state ~= "failed" and allowed[self.state] and allowed[self.state].failed then
    self:_transition("failed")
  end
  self:_record_error(err)
  self:_finish_operation(operation, err)
end

function Session:_required_v2_error(err)
  if unsupported_v2(err) then return { message = UPGRADE_DIAGNOSTIC, cause = err } end
  return error_value(err)
end

function Session:_matches_active(params)
  if not self.turn_id then return false end
  if params and params.threadId and params.threadId ~= self.thread_id then return false end
  if params and params.turnId and params.turnId ~= self.turn_id then return false end
  return true
end

function Session:_candidate_turn_id(method, params)
  if method == "turn/completed" then
    return params and params.turn and params.turn.id
  end
  return params and params.turnId
end

function Session:_queue_candidate(method, params)
  local candidate = self._pending_turn
  if not candidate or candidate.generation ~= self.generation then return false end
  if params and params.threadId and params.threadId ~= self.thread_id then return false end
  local turn_id = self:_candidate_turn_id(method, params)
  if type(turn_id) ~= "string" or turn_id == "" then return false end
  candidate.notifications[#candidate.notifications + 1] = {
    method = method,
    params = params,
    turn_id = turn_id,
  }
  return true
end

function Session:_process_delta(params)
  if not self._assistant_entry then
    self._assistant_entry = { type = "assistant", text = "" }
    self.transcript[#self.transcript + 1] = self._assistant_entry
  end
  self._assistant_entry.text = self._assistant_entry.text .. (params.delta or "")
  self:_emit("item/agentMessage/delta", params)
end

function Session:_process_item(method, status, params)
  self.transcript[#self.transcript + 1] = {
    type = "activity",
    status = status,
    item = params and params.item or params,
  }
  self:_emit(method, params)
end

function Session:_retire_commands(status, decision, connected)
  local retired = false
  for request_id, pending in pairs(self.pending_commands) do
    retired = true
    pending.entry.status = status
    pending.entry.decision = decision
    if connected and decision and not pending.responded then
      pending.responded = true
      local ok, err = self.transport:respond(request_id, { decision = decision })
      if not ok and err then self:_record_error(err) end
    end
    self.pending_commands[request_id] = nil
  end
  return retired
end

function Session:_process_turn_completed(params)
  local turn = params and params.turn or {}
  if not self.turn_id or turn.id ~= self.turn_id then return end
  self.turn_id = nil
  self._assistant_entry = nil
  if self.state == "waiting_for_command_approval" then
    self:_retire_commands("expired", "decline", true)
    self:_transition("running")
  end
  if self.state ~= "running" then return end
  self:_emit("turn/completed", params)
  local generation = self.generation
  local completed = once(function(err)
    if not self:_generation_current(generation) then return end
    if err then self:_fail(err); return end
    local files = self.review:files()
    self:_transition(#files > 0 and "reviewable" or "idle")
  end)
  local ok, thrown = pcall(self.review.refresh, self.review, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:_receive_turn_notification(method, params)
  if self:_matches_active(params) then
    if method == "item/agentMessage/delta" then
      self:_process_delta(params)
    elseif method == "item/started" then
      self:_process_item(method, "started", params)
    elseif method == "item/completed" then
      self:_process_item(method, "completed", params)
    elseif method == "turn/completed" then
      self:_process_turn_completed(params)
    end
    return
  end
  self:_queue_candidate(method, params)
end

function Session:_on_protocol_error(params)
  local err = params and (params.error or params) or { message = "app-server error" }
  if err.code == "unknown_notification" then return end
  self:_record_error(err)
end

function Session:_on_file_approval(params, request_id)
  if not request_id then return end
  local decision = "decline"
  local active = (self.state == "running" or self.state == "waiting_for_command_approval")
    and self.shadow and self.shadow.workspace_root and self.thread_id and self.turn_id
    and params and params.threadId == self.thread_id and params.turnId == self.turn_id
  if active then
    local safe = no_follow_grant(self.shadow, params.grantRoot)
    if safe then decision = "acceptForSession" end
  end
  local ok, err = self.transport:respond(request_id, { decision = decision })
  if not ok and err then self:_record_error(err) end
  self:_emit("item/fileChange/requestApproval", {
    requestId = request_id,
    request = params,
    decision = decision,
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
  self.pending_commands[request_id] = { params = params, entry = entry, responded = false }
  self.transcript[#self.transcript + 1] = entry
  self:_transition("waiting_for_command_approval")
  self:_emit("item/commandExecution/requestApproval", {
    requestId = request_id,
    request = params,
  })
end

function Session:_register_handlers()
  for _, method in ipairs({
    "item/agentMessage/delta",
    "item/started",
    "item/completed",
    "turn/completed",
  }) do
    self:_listen(method, function(params) self:_receive_turn_notification(method, params) end)
  end
  self:_listen("item/fileChange/requestApproval",
    function(params, id) self:_on_file_approval(params, id) end)
  self:_listen("item/commandExecution/requestApproval",
    function(params, id) self:_on_command_approval(params, id) end)
  self:_listen("error", function(params) self:_on_protocol_error(params) end)
  self:_listen("turn/error", function(params) self:_on_protocol_error(params) end)
  self:_listen("exit", function(result) self:_on_exit(result) end)
end

function Session:_start_thread(generation, operation, opts)
  opts = opts or {}
  if not self.shadow or not self.shadow.workspace_root then
    self:_fail({ message = "cannot start a thread without a shadow workspace" }, operation)
    return
  end
  local params = {
    ephemeral = true,
    cwd = self.shadow.workspace_root,
    approvalPolicy = "untrusted",
    permissions = ":workspace",
  }
  local completed = once(function(err, result)
    if not self:_generation_current(generation) then return end
    if err then
      self:_fail(self:_required_v2_error(err), operation)
      return
    end
    local thread_id = result and result.thread and result.thread.id
    if type(thread_id) ~= "string" or thread_id == "" then
      self:_fail({ message = "thread/start returned no thread id" }, operation)
      return
    end
    self.thread_id = thread_id
    local target = opts.target or "idle"
    self:_transition(target)
    if opts.restarting then self:_emit("restarted", { threadId = thread_id }) end
    self:_finish_operation(operation, nil, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport,
    "thread/start", params, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:_ensure_workspace(generation, operation, opts)
  opts = opts or {}
  local function start_thread()
    if not self.review then
      local ok, value = pcall(self.review_factory, self.shadow)
      if not ok then self:_fail(error_value(value), operation); return end
      self.review = value
    end
    if not self.context then
      self.context = Context.new(self.shadow.project_root or self.root)
    end
    self:_start_thread(generation, operation, opts)
  end
  if self.shadow then
    start_thread()
    return
  end
  local created = once(function(err, shadow)
    if not self:_generation_current(generation) then
      if shadow then cleanup_shadow(shadow) end
      return
    end
    if err then self:_fail(err, operation); return end
    if not shadow then
      self:_fail({ message = "shadow creation returned no workspace" }, operation)
      return
    end
    self.shadow = shadow
    start_thread()
  end)
  local ok, thrown = pcall(self.create_shadow, {
    root = self.root,
    temp_parent = self.temp_parent,
  }, created)
  if not ok then created(error_value(thrown)) end
end

function Session:_initialize_after_transport(generation, operation, opts)
  opts = opts or {}
  local checked = once(function(err, account)
    if not self:_generation_current(generation) then return end
    if err then self:_fail(err, operation); return end
    if not account or not account.authenticated then
      self:_transition("auth_required")
      self:_finish_operation(operation, nil, account)
      return
    end
    self:_ensure_workspace(generation, operation, opts)
  end)
  local ok, thrown = pcall(self.auth.check, self.auth, checked)
  if not ok then checked(error_value(thrown)) end
end

function Session:_start_transport(generation, operation, opts)
  opts = opts or {}
  local started = once(function(err)
    if not self:_generation_current(generation) then return end
    if err then self:_fail(err, operation); return end
    if opts.recovery and self.shadow then
      self:_ensure_workspace(generation, operation, opts)
    else
      self:_initialize_after_transport(generation, operation, opts)
    end
  end)
  local ok, thrown = pcall(self.transport.start, self.transport, started)
  if not ok then started(error_value(thrown)) end
end

function Session:_on_exit(result)
  if self._expected_exit or self.disposed or not self.started
    or self.state == "closing" then return end
  local err = {
    message = "app-server exited unexpectedly",
    code = result and result.code,
    signal = result and result.signal,
  }
  self._settling = true
  local pending = self:_invalidate_operations()
  self:_retire_commands("failed", nil, false)
  self.turn_id = nil
  self.thread_id = nil
  self._assistant_entry = nil
  if self.state ~= "failed" and allowed[self.state] and allowed[self.state].failed then
    self:_transition("failed")
  end
  self:_record_error(err)
  local restarting = not self.restart_attempted and not self.disposed
    and self.state == "failed"
  if restarting then
    self.restart_attempted = true
    self:_transition("starting")
    if not self.disposed and self.state == "starting" then
      self:_emit("restart", { attempt = 1 })
    else
      restarting = false
    end
  end
  self:_settle_operations(pending, err)
  self:_cancel_review_queue(err)
  self._settling = false
  if not restarting or self.disposed or self.state ~= "starting" then return end
  local generation = self.generation
  local function restart_after_refresh(refresh_err)
    if not self:_generation_current(generation) or self.state ~= "starting" then return end
    if refresh_err then
      self:_fail(refresh_err)
      return
    end
    local target = self.review and #self.review:files() > 0 and "reviewable" or "idle"
    self:_start_transport(generation, nil, {
      recovery = true,
      restarting = true,
      target = target,
    })
  end
  self:_when_review_idle(function()
    if not self:_generation_current(generation) or self.state ~= "starting" then return end
    if self.shadow and self.review and type(self.review.refresh) == "function" then
      local completed = once(restart_after_refresh)
      local ok, thrown = pcall(self.review.refresh, self.review, completed)
      if not ok then completed(error_value(thrown)) end
    else
      restart_after_refresh()
    end
  end)
end

function Session:start(callback)
  callback = public_callback(callback)
  if self:_reject_reentry(callback) then return end
  if self.disposed then
    callback(state_error("session is disposed and cannot be reopened"))
    return
  end
  if self.state ~= "closed" and self.state ~= "failed" then
    callback(state_error("session can only start while closed or failed"))
    return
  end
  if self.state == "failed" then
    self._settling = true
    local pending = self:_invalidate_operations()
    self:_settle_operations(pending, { message = "session retrying" })
    self._settling = false
    if self.disposed or self.state ~= "failed" then
      callback(state_error("session cannot retry after a lifecycle transition"))
      return
    end
    local operation = self:_new_operation(callback)
    local generation = self.generation
    self.restart_attempted = false
    self._expected_exit = true
    local stopped = once(function(err)
      self._expected_exit = false
      if not self:_operation_current(operation) then return end
      if err then self:_fail(err, operation); return end
      self:_transition("starting")
      self:_start_transport(generation, operation, { target = "idle" })
    end)
    local ok, thrown = pcall(self.transport.stop, self.transport, stopped)
    if not ok then stopped(error_value(thrown)) end
    return
  end
  self.started = true
  local operation = self:_new_operation(callback)
  self:_transition("starting")
  self:_start_transport(self.generation, operation, { target = "idle" })
end

function Session:login(callback)
  callback = public_callback(callback)
  if self:_reject_reentry(callback) then return end
  if self.disposed then
    callback(state_error("session is disposed"))
    return
  end
  if self.state ~= "auth_required" then
    callback(state_error("login requires an auth_required session"))
    return
  end
  local operation = self:_new_operation(callback)
  local generation = self.generation
  local logged_in = once(function(err)
    if not self:_operation_current(operation) then return end
    if err then
      self:_record_error(err)
      self:_finish_operation(operation, err)
      return
    end
    self:_ensure_workspace(generation, operation, { target = "idle" })
  end)
  local ok, thrown = pcall(self.auth.login, self.auth, logged_in)
  if not ok then logged_in(error_value(thrown)) end
end

function Session:send(text, callback)
  callback = public_callback(callback)
  if self:_reject_reentry(callback) then return end
  if self.disposed then callback(state_error("session is disposed")); return end
  if (self.state ~= "idle" and self.state ~= "reviewable") or self._sending
      or self._review_active or #self._review_queue > 0 then
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
  local operation = self:_new_operation(callback)
  local generation = self.generation
  self._sending = true
  local synced = once(function(sync_err)
    if not self:_operation_current(operation) then return end
    self._sending = false
    if sync_err then
      sync_err = error_value(sync_err)
      if sync_err.code == "conflict" then
        self:_emit("conflict", sync_err)
        local reconcile_err = self:_reconcile_review_state()
        if reconcile_err then self:_record_error(reconcile_err) end
      end
      self:_finish_operation(operation, sync_err)
      return
    end
    local ok_inputs, inputs = pcall(self.context.inputs, self.context, text)
    if not ok_inputs then self:_finish_operation(operation, error_value(inputs)); return end
    self:_transition("running")
    self._assistant_entry = nil
    local candidate = { generation = generation, notifications = {} }
    self._pending_turn = candidate
    local completed = once(function(err, result)
      if not self:_operation_current(operation) then return end
      self._pending_turn = nil
      if err then
        self:_fail(self:_required_v2_error(err), operation)
        return
      end
      local turn_id = result and result.turn and result.turn.id
      if type(turn_id) ~= "string" or turn_id == "" then
        self:_fail({ message = "turn/start returned no turn id" }, operation)
        return
      end
      self.turn_id = turn_id
      self.context:clear()
      local entry = { type = "user", text = text, input = inputs }
      self.transcript[#self.transcript + 1] = entry
      self:_emit("user", entry)
      self:_finish_operation(operation, nil, result)
      for _, notification in ipairs(candidate.notifications) do
        if notification.turn_id == turn_id and self:_generation_current(generation) then
          self:_receive_turn_notification(notification.method, notification.params)
        end
      end
    end)
    local params = {
      threadId = self.thread_id,
      input = inputs,
    }
    local ok, thrown = pcall(self.transport.request, self.transport,
      "turn/start", params, completed)
    if not ok then completed(error_value(thrown)) end
  end)
  local ok, thrown = pcall(self.review.sync_live, self.review, synced)
  if not ok then synced(error_value(thrown)) end
end

function Session:steer(text, callback)
  callback = public_callback(callback)
  if self:_reject_reentry(callback) then return end
  if self.disposed then callback(state_error("session is disposed")); return end
  if self.state ~= "running" or not self.turn_id then
    callback(state_error("steer requires an active turn"))
    return
  end
  if type(text) ~= "string" or vim.trim(text) == "" then
    callback({ code = "invalid_prompt", message = "steer text must not be blank" })
    return
  end
  local operation = self:_new_operation(callback)
  local completed = once(function(err, result)
    if not self:_operation_current(operation) then return end
    if err then self:_record_error(err) end
    self:_finish_operation(operation, err, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport, "turn/steer", {
    threadId = self.thread_id,
    expectedTurnId = self.turn_id,
    input = { { type = "text", text = text } },
  }, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:approve_command(request_id, decision)
  if self._settling or self.disposed then
    return false, state_error("session lifecycle transition in progress")
  end
  local pending = self.pending_commands[request_id]
  if not pending then return false, { message = "unknown command approval request" } end
  if type(decision) ~= "string" or decision == "" then
    return false, { message = "command approval decision is required" }
  end
  local ok, err = self.transport:respond(request_id, { decision = decision })
  if not ok then return false, err end
  pending.responded = true
  pending.entry.status = "decided"
  pending.entry.decision = decision
  self.pending_commands[request_id] = nil
  if self.state == "waiting_for_command_approval" then self:_transition("running") end
  return true
end

function Session:cancel(callback)
  callback = public_callback(callback)
  if self:_reject_reentry(callback) then return end
  if self.disposed then callback(state_error("session is disposed")); return end
  if (self.state ~= "running" and self.state ~= "waiting_for_command_approval")
    or not self.turn_id then
    callback(state_error("cancel requires an active turn"))
    return
  end
  if self.state == "waiting_for_command_approval" then
    self:_retire_commands("cancelled", "cancel", true)
    self:_transition("running")
  end
  local operation = self:_new_operation(callback)
  local completed = once(function(err, result)
    if not self:_operation_current(operation) then return end
    if err then self:_record_error(err) end
    self:_finish_operation(operation, err, result)
  end)
  local ok, thrown = pcall(self.transport.request, self.transport, "turn/interrupt", {
    threadId = self.thread_id,
    turnId = self.turn_id,
  }, completed)
  if not ok then completed(error_value(thrown)) end
end

function Session:close(callback)
  callback = public_callback(callback)
  if self.state == "closing" then
    self._close_callbacks[#self._close_callbacks + 1] = callback
    return
  end
  if self.disposed then callback(); return end
  self._close_callbacks = { callback }
  local active_turn = self.turn_id
  self.disposed = true
  local pending = self:_invalidate_operations()
  self:_transition("closing")
  self:_retire_commands("cancelled", "cancel", true)
  self:_unregister_handlers()
  self.turn_id = nil
  self._assistant_entry = nil
  if active_turn then
    pcall(self.transport.request, self.transport, "turn/interrupt", {
      threadId = self.thread_id,
      turnId = active_turn,
    }, noop)
  end
  self:_settle_operations(pending, { message = "session closing" })
  self:_cancel_review_queue({ code = "closing", message = "session closing" })
  local remaining = 2
  local first_error
  local function finished(err)
    if err and not first_error then first_error = error_value(err) end
    remaining = remaining - 1
    if remaining ~= 0 then return end
    self:_transition("closed")
    self.thread_id = nil
    self.shadow = nil
    local callbacks = self._close_callbacks
    self._close_callbacks = nil
    for _, close_callback in ipairs(callbacks) do close_callback(first_error) end
  end
  local stopped = once(finished)
  local ok_stop, stop_err = pcall(self.transport.stop, self.transport, stopped)
  if not ok_stop then stopped(error_value(stop_err)) end
  self:_when_review_idle(function()
    local cleaned = once(finished)
    if self.shadow and self.shadow.cleanup then
      local ok_cleanup, cleanup_err = pcall(self.shadow.cleanup, self.shadow, cleaned)
      if not ok_cleanup then cleaned(error_value(cleanup_err)) end
    else
      cleaned()
    end
  end)
end

return Session
