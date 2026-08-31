local scenario = arg[#arg] or "initialize"

local function send(value)
  io.stdout:write(vim.json.encode(value) .. "\n")
  io.stdout:flush()
end

local function respond(message, result)
  send({ id = message.id, result = result or {} })
end

local function reject(message, text)
  send({ id = message.id, error = { code = -32602, message = text } })
end

local function notify(method, params)
  send({ method = method, params = params or {} })
end

local thread_id = "thread-" .. scenario
local thread_cwd
local turn_id
local turn_count = 0
local pending_approval

local function complete(status)
  notify("turn/completed", {
    threadId = thread_id,
    turn = { id = turn_id, status = status or "completed" },
  })
end

local function valid_thread_start(params)
  return params.ephemeral == true
    and type(params.cwd) == "string"
    and params.approvalPolicy == "untrusted"
    and params.sandbox == "workspaceWrite"
end

local function valid_turn_start(params)
  local policy = params.sandboxPolicy
  return params.threadId == thread_id
    and type(params.input) == "table"
    and type(policy) == "table"
    and policy.type == "workspaceWrite"
    and vim.deep_equal(policy.writableRoots, { thread_cwd })
    and vim.deep_equal(policy.readOnlyAccess, {
      type = "restricted",
      includePlatformDefaults = true,
      readableRoots = { thread_cwd },
    })
    and policy.networkAccess == false
end

local function crash_marker()
  return vim.fs.dirname(thread_cwd) .. "/control/fake-app-server-crashed"
end

io.stderr:write("fake app server started: " .. scenario .. "\n")
io.stderr:flush()

for line in io.lines() do
  local message = vim.json.decode(line)
  if message.id and not message.method then
    if pending_approval and message.id == pending_approval.id then
      local decision = message.result and message.result.decision
      local valid = pending_approval.kind == "file" and decision == "acceptForSession"
        or pending_approval.kind == "command" and type(decision) == "string"
      if not valid then os.exit(31) end
      pending_approval = nil
      complete("completed")
    end
  elseif message.method == "initialize" then
    respond(message)
  elseif message.method == "account/read" then
    local account = {
      requiresOpenaiAuth = true,
      refreshToken = message.params.refreshToken,
    }
    if scenario ~= "account-required" then account.account = { type = "chatgpt" } end
    respond(message, account)
  elseif message.method == "account/login/start" then
    respond(message, {
      type = "chatgpt",
      loginId = "login-1",
      authUrl = "https://chatgpt.com/auth",
    })
    notify("account/login/completed", { loginId = "login-1", success = true })
  elseif message.method == "initialized" then
    io.stderr:write("initialized\n")
    io.stderr:flush()
  elseif message.method == "thread/start" then
    if not valid_thread_start(message.params) then
      reject(message, "invalid ephemeral shadow thread policy")
    else
      thread_cwd = message.params.cwd
      respond(message, { thread = { id = thread_id } })
    end
  elseif message.method == "turn/start" then
    if not valid_turn_start(message.params) then
      reject(message, "invalid restricted sandbox policy")
    elseif scenario == "unsupported-sandbox" then
      reject(message, "unknown field `readOnlyAccess`")
    else
      turn_count = turn_count + 1
      turn_id = "turn-" .. turn_count
      respond(message, { turn = { id = turn_id } })
      if scenario == "streamed-turn" then
        notify("item/started", {
          threadId = thread_id,
          turnId = turn_id,
          item = { id = "item-1", type = "agentMessage" },
        })
        notify("item/agentMessage/delta", {
          threadId = thread_id,
          turnId = turn_id,
          itemId = "item-1",
          delta = "streamed ",
        })
        notify("item/agentMessage/delta", {
          threadId = thread_id,
          turnId = turn_id,
          itemId = "item-1",
          delta = "response",
        })
        notify("item/completed", {
          threadId = thread_id,
          turnId = turn_id,
          item = { id = "item-1", type = "agentMessage" },
        })
        complete("completed")
      elseif scenario == "file-approval" then
        pending_approval = { id = 700, kind = "file" }
        send({
          id = pending_approval.id,
          method = "item/fileChange/requestApproval",
          params = { threadId = thread_id, turnId = turn_id, itemId = "file-1" },
        })
      elseif scenario == "command-approval" then
        pending_approval = { id = 701, kind = "command" }
        send({
          id = pending_approval.id,
          method = "item/commandExecution/requestApproval",
          params = {
            threadId = thread_id,
            turnId = turn_id,
            itemId = "command-1",
            command = { "make", "test" },
          },
        })
      elseif scenario == "failed-turn" then
        notify("item/agentMessage/delta", {
          threadId = thread_id,
          turnId = turn_id,
          delta = "partial result",
        })
        complete("failed")
      elseif scenario == "crash-once" then
        local marker = crash_marker()
        local existing = io.open(marker, "rb")
        if existing then
          existing:close()
          complete("completed")
        else
          local created = assert(io.open(marker, "wb"))
          created:write("crashed\n")
          created:close()
          os.exit(23)
        end
      else
        complete("completed")
      end
    end
  elseif message.method == "turn/steer" then
    if message.params.threadId ~= thread_id or message.params.expectedTurnId ~= turn_id then
      reject(message, "unknown active turn")
    else
      respond(message)
    end
  elseif message.method == "turn/interrupt" then
    respond(message)
    if turn_id then complete("interrupted") end
  elseif message.method == "never/respond" then
    -- Used by the transport stop test to leave one request pending.
  elseif message.id then
    reject(message, "unsupported fake method: " .. tostring(message.method))
  end
end
