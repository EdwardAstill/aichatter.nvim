local h = require("tests.helpers")
local Session = require("aichatter.session")
local Context = require("aichatter.context")
local Transport = require("aichatter.transport")

local function requests(transport, method)
  local found = {}
  for _, request in ipairs(transport.requests) do
    if request.method == method then found[#found + 1] = request end
  end
  return found
end

local function event_names(events)
  local names = {}
  for _, event in ipairs(events) do names[#names + 1] = event.name end
  return names
end

local function real_server_fixture(scenario, opts)
  opts = opts or {}
  local project_root = h.tempdir()
  local session_root = h.tempdir()
  local workspace_root = session_root .. "/workspace"
  local baseline_root = session_root .. "/control/baseline"
  h.mkdir(workspace_root)
  h.mkdir(baseline_root)
  local files = opts.files or {}
  local review = {
    refresh_count = 0,
    sync_count = 0,
    refresh = function(self, callback)
      self.refresh_count = self.refresh_count + 1
      callback()
    end,
    sync_live = function(self, callback)
      self.sync_count = self.sync_count + 1
      callback()
    end,
    files = function() return files end,
  }
  local shadow = {
    project_root = project_root,
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    cleanup = function(_, callback) callback() end,
  }
  local transport = Transport.new({
    cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l",
      "tests/fixtures/fake_app_server.lua", scenario },
  })
  local events = {}
  local session = Session.new({
    transport = transport,
    shadow = shadow,
    review = review,
    context = Context.new(project_root),
    emit = function(name, value)
      events[#events + 1] = { name = name, value = value }
    end,
  })
  return {
    session = session,
    transport = transport,
    review = review,
    shadow = shadow,
    events = events,
  }
end

local function close_real_fixture(fixture)
  local closed = false
  fixture.session:close(function(err)
    h.eq(nil, err)
    closed = true
  end)
  h.truthy(h.wait_for(function() return closed end, 2000))
end

h.test("rejects invalid explicit session transitions", function()
  local session = Session.new({ transport = h.fake_transport({}), emit = function() end })

  h.raises("invalid session transition closed %-%> reviewable", function()
    session:_transition("reviewable")
  end)
end)

h.test("does not expose review until turn completion", function()
  local fixture = h.session_fixture()
  fixture.session:send("Change main.lua")
  fixture.transport:emit("item/agentMessage/delta", { delta = "Working" })

  h.eq("running", fixture.session.state)
  h.eq(0, fixture.review.refresh_count)
  fixture.transport:emit("turn/completed", {
    turn = { id = "turn-1", status = "completed" },
  })

  h.eq(1, fixture.review.refresh_count)
  h.eq("reviewable", fixture.session.state)
  h.eq({ "state", "user", "item/agentMessage/delta", "turn/completed", "state" },
    event_names(fixture.events))
  h.eq("Working", fixture.session.transcript[2].text)
end)

h.test("uses the same ephemeral thread for follow-up turns", function()
  local next_turn = 0
  local fixture = h.session_fixture({
    files = {},
    responses = {
      ["turn/start"] = function(_, callback)
        next_turn = next_turn + 1
        callback(nil, { turn = { id = "turn-" .. next_turn } })
      end,
    },
  })

  fixture.session:send("First")
  fixture.transport:emit("turn/completed", {
    turn = { id = "turn-1", status = "completed" },
  })
  fixture.session:send("Second")

  local turns = requests(fixture.transport, "turn/start")
  h.eq(2, #turns)
  h.eq("thread-1", turns[1].params.threadId)
  h.eq("thread-1", turns[2].params.threadId)
  h.eq(0, #requests(fixture.transport, "thread/start"))
end)

h.test("steers only an active turn", function()
  local fixture = h.session_fixture()
  local idle_error

  fixture.session:steer("Too early", function(err) idle_error = err end)
  h.matches("active turn", idle_error.message)
  h.eq(0, #requests(fixture.transport, "turn/steer"))

  fixture.session:send("Begin")
  local steer_error
  fixture.session:steer("Focus on tests", function(err) steer_error = err end)
  h.eq(nil, steer_error)
  h.eq({
    threadId = "thread-1",
    expectedTurnId = "turn-1",
    input = { { type = "text", text = "Focus on tests" } },
  }, requests(fixture.transport, "turn/steer")[1].params)
end)

h.test("clears one-shot context only after a successful turn start", function()
  local pending
  local context = Context.new("/project")
  context:add_file("main.lua")
  local fixture = h.session_fixture({
    context = context,
    responses = {
      ["turn/start"] = function(_, callback) pending = callback end,
    },
  })

  fixture.session:send("Change it")
  h.eq(2, #context:inputs("Still pending"))
  pending({ message = "rejected" })
  h.eq(2, #context:inputs("Retry"))
  h.eq("failed", fixture.session.state)

  local success_context = Context.new("/project")
  success_context:add_file("main.lua")
  local success = h.session_fixture({ context = success_context })
  success.session:send("Change it")
  h.eq(1, #success_context:inputs("Next"))
end)

h.test("sends the exact restricted v2 turn payload", function()
  local fixture = h.session_fixture()

  fixture.session:send("Edit safely")

  h.eq({
    threadId = "thread-1",
    input = { { type = "text", text = "Edit safely" } },
    sandboxPolicy = {
      type = "workspaceWrite",
      writableRoots = { "/shadow/workspace" },
      readOnlyAccess = {
        type = "restricted",
        includePlatformDefaults = true,
        readableRoots = { "/shadow/workspace" },
      },
      networkAccess = false,
    },
  }, requests(fixture.transport, "turn/start")[1].params)
end)

h.test("refreshes proposals after failed and interrupted turn completion", function()
  for _, status in ipairs({ "failed", "interrupted" }) do
    local fixture = h.session_fixture()
    fixture.session:send("Try")

    fixture.transport:emit("turn/completed", {
      turn = { id = "turn-1", status = status },
    })

    h.eq(1, fixture.review.refresh_count)
    h.eq("reviewable", fixture.session.state)
    h.eq(nil, fixture.session.turn_id)
  end
end)

h.test("auto-accepts shadow file requests but waits on command requests", function()
  local fixture = h.session_fixture()

  fixture.transport:server_request(41, "item/fileChange/requestApproval", { itemId = "f1" })
  h.eq("acceptForSession", fixture.transport.responses[41].result.decision)

  fixture.session:send("Run checks")
  fixture.transport:server_request(42, "item/commandExecution/requestApproval", {
    command = { "make", "test" },
  })
  h.eq("waiting_for_command_approval", fixture.session.state)
  h.eq(nil, fixture.transport.responses[42])

  fixture.session:approve_command(42, "decline")
  h.eq("decline", fixture.transport.responses[42].result.decision)
  h.eq("running", fixture.session.state)
end)

h.test("does not auto-accept file approvals without a disposable shadow thread", function()
  local transport = h.fake_transport({})
  Session.new({ transport = transport, emit = function() end })

  transport:server_request(7, "item/fileChange/requestApproval", { itemId = "f1" })

  h.eq(nil, transport.responses[7])
end)

h.test("does not auto-accept a file approval granting an external root", function()
  local fixture = h.session_fixture()

  fixture.transport:server_request(8, "item/fileChange/requestApproval", {
    itemId = "f1",
    grantRoot = "/project",
  })
  fixture.transport:server_request(9, "item/fileChange/requestApproval", {
    itemId = "f2",
    grantRoot = "/shadow/workspace/generated",
  })

  h.eq(nil, fixture.transport.responses[8])
  h.eq("acceptForSession", fixture.transport.responses[9].result.decision)
end)

h.test("cancel interrupts the active turn and retains the shadow", function()
  local fixture = h.session_fixture()
  fixture.session:send("Change it")
  local calls, cancel_error = 0

  fixture.session:cancel(function(err)
    calls = calls + 1
    cancel_error = err
  end)

  h.eq(nil, cancel_error)
  h.eq(1, calls)
  h.eq({ threadId = "thread-1", turnId = "turn-1" },
    requests(fixture.transport, "turn/interrupt")[1].params)
  h.eq(0, fixture.shadow.cleanup_count)
  h.eq("running", fixture.session.state)
end)

h.test("aborts conflicted live synchronization and emits affected paths", function()
  local review = {
    refresh = function(_, callback) callback() end,
    files = function() return {} end,
    sync_live = function(_, callback)
      callback({ code = "conflict", paths = { "a.lua", "b.lua" } })
    end,
  }
  local fixture = h.session_fixture({ review = review, files = {} })
  local calls, send_error = 0

  fixture.session:send("Continue", function(err)
    calls = calls + 1
    send_error = err
  end)

  h.eq(1, calls)
  h.eq("conflict", send_error.code)
  h.eq("idle", fixture.session.state)
  h.eq(0, #requests(fixture.transport, "turn/start"))
  h.eq("conflict", fixture.events[1].name)
  h.eq({ "a.lua", "b.lua" }, fixture.events[1].value.paths)
end)

h.test("fails with the exact upgrade diagnostic without weakening sandbox policy", function()
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback)
        callback({ message = "unknown field `readOnlyAccess`" })
      end,
    },
  })
  local captured

  fixture.session:send("Try", function(err) captured = err end)

  h.eq("Codex CLI is too old for aichatter.nvim; upgrade Codex and retry.", captured.message)
  h.eq("failed", fixture.session.state)
  h.eq(1, #requests(fixture.transport, "turn/start"))
  h.eq("restricted",
    requests(fixture.transport, "turn/start")[1].params.sandboxPolicy.readOnlyAccess.type)
end)

h.test("starts transport then auth then shadow then one ephemeral thread", function()
  local order = {}
  local transport = h.fake_transport({
    ["thread/start"] = function(_, callback)
      order[#order + 1] = "thread"
      callback(nil, { thread = { id = "thread-new" } })
    end,
  })
  local original_start = transport.start
  function transport:start(callback)
    order[#order + 1] = "transport"
    original_start(self, callback)
  end
  local shadow = {
    project_root = "/project",
    baseline_root = "/tmp/session/control/baseline",
    workspace_root = "/tmp/session/workspace",
  }
  local auth = {
    check = function(_, callback)
      order[#order + 1] = "auth"
      callback(nil, { authenticated = true })
    end,
  }
  local session = Session.new({
    transport = transport,
    auth = auth,
    root = "/project",
    create_shadow = function(_, callback)
      order[#order + 1] = "shadow"
      callback(nil, shadow)
    end,
    review_factory = function() return {
      refresh = function(_, callback) callback() end,
      sync_live = function(_, callback) callback() end,
      files = function() return {} end,
    } end,
    emit = function() end,
  })
  local calls, start_error = 0

  session:start(function(err)
    calls = calls + 1
    start_error = err
  end)

  h.eq(nil, start_error)
  h.eq(1, calls)
  h.eq({ "transport", "auth", "shadow", "thread" }, order)
  h.eq("idle", session.state)
  h.eq({
    ephemeral = true,
    cwd = "/tmp/session/workspace",
    approvalPolicy = "untrusted",
    sandbox = "workspaceWrite",
  }, requests(transport, "thread/start")[1].params)
end)

h.test("requires login before creating a shadow", function()
  local checks = 0
  local auth = {
    check = function(_, callback)
      checks = checks + 1
      callback(nil, { authenticated = false })
    end,
    login = function(_, callback) callback(nil, { success = true }) end,
  }
  local created = 0
  local transport = h.fake_transport({
    ["thread/start"] = { thread = { id = "thread-new" } },
  })
  local shadow = {
    project_root = "/project",
    baseline_root = "/tmp/session/control/baseline",
    workspace_root = "/tmp/session/workspace",
  }
  local session = Session.new({
    transport = transport,
    auth = auth,
    create_shadow = function(_, callback)
      created = created + 1
      callback(nil, shadow)
    end,
    review_factory = function() return {
      refresh = function(_, callback) callback() end,
      sync_live = function(_, callback) callback() end,
      files = function() return {} end,
    } end,
    emit = function() end,
  })

  session:start()
  h.eq("auth_required", session.state)
  h.eq(0, created)
  session:login()
  h.eq("idle", session.state)
  h.eq(1, created)
  h.eq(1, checks)
end)

h.test("rejects unsupported ephemeral threads with the upgrade diagnostic", function()
  local transport = h.fake_transport({
    ["thread/start"] = function(_, callback)
      callback({ message = "unsupported field ephemeral" })
    end,
  })
  local session = Session.new({
    transport = transport,
    auth = { check = function(_, callback) callback(nil, { authenticated = true }) end },
    shadow = {
      project_root = "/project",
      baseline_root = "/shadow/control/baseline",
      workspace_root = "/shadow/workspace",
    },
    review = {},
    emit = function() end,
  })
  local captured

  session:start(function(err) captured = err end)

  h.eq("Codex CLI is too old for aichatter.nvim; upgrade Codex and retry.", captured.message)
  h.eq("failed", session.state)
  h.eq(1, #requests(transport, "thread/start"))
end)

h.test("restarts once with the same shadow review and transcript", function()
  local fixture = h.session_fixture()
  fixture.session:send("Before crash")
  local shadow = fixture.session.shadow
  local review = fixture.session.review
  local transcript = fixture.session.transcript

  fixture.transport:emit("exit", { code = 23 })

  h.eq(1, fixture.transport.starts)
  h.eq("idle", fixture.session.state)
  h.eq("thread-restarted", fixture.session.thread_id)
  h.eq(shadow, fixture.session.shadow)
  h.eq(review, fixture.session.review)
  h.eq(transcript, fixture.session.transcript)
  h.eq("Before crash", transcript[1].text)

  fixture.session:send("After restart")
  fixture.transport:emit("exit", { code = 24 })
  h.eq(1, fixture.transport.starts)
  h.eq("failed", fixture.session.state)
end)

h.test("invokes callbacks once and ignores duplicate turn completion", function()
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback)
        callback(nil, { turn = { id = "turn-1" } })
        callback(nil, { turn = { id = "turn-other" } })
      end,
    },
  })
  local calls = 0
  fixture.session:send("Once", function() calls = calls + 1 end)
  local completed = { turn = { id = "turn-1", status = "completed" } }
  fixture.transport:emit("turn/completed", completed)
  fixture.transport:emit("turn/completed", completed)

  h.eq(1, calls)
  h.eq(1, fixture.review.refresh_count)
end)

h.test("close cleans handlers and calls completion once", function()
  local transport = h.fake_transport({
    __stop = function(_, callback)
      callback(nil)
      callback({ message = "duplicate" })
    end,
  })
  local cleanup_count = 0
  local shadow = {
    workspace_root = "/shadow/workspace",
    cleanup = function(_, callback)
      cleanup_count = cleanup_count + 1
      callback(nil)
      callback({ message = "duplicate" })
    end,
  }
  local session = Session.new({
    transport = transport,
    shadow = shadow,
    review = {},
    emit = function() end,
  })
  session.state, session.thread_id = "idle", "thread-1"
  local calls, close_error = 0

  session:close(function(err)
    calls = calls + 1
    close_error = err
  end)

  h.eq(nil, close_error)
  h.eq(1, calls)
  h.eq(1, transport.stops)
  h.eq(1, cleanup_count)
  h.eq(0, transport:total_listener_count())
  h.eq("closed", session.state)
end)

h.test("fake app-server supports authenticated and account-required startup", function()
  local authenticated = real_server_fixture("authenticated")
  authenticated.session:start()
  h.truthy(h.wait_for(function() return authenticated.session.state == "idle" end, 2000))
  close_real_fixture(authenticated)

  local required = real_server_fixture("account-required")
  required.session:start()
  h.truthy(h.wait_for(function() return required.session.state == "auth_required" end, 2000))
  close_real_fixture(required)
end)

h.test("fake app-server streams item lifecycle and completes a turn in order", function()
  local fixture = real_server_fixture("streamed-turn")
  fixture.session:start()
  h.truthy(h.wait_for(function() return fixture.session.state == "idle" end, 2000))

  fixture.session:send("Stream")
  h.truthy(h.wait_for(function()
    return fixture.review.refresh_count == 1 and fixture.session.state == "idle"
  end, 2000))

  h.eq("streamed response", fixture.session.transcript[3].text)
  h.eq({
    "state", "state", "state", "user", "item/started",
    "item/agentMessage/delta", "item/agentMessage/delta", "item/completed",
    "turn/completed", "state",
  }, event_names(fixture.events))
  close_real_fixture(fixture)
end)

h.test("fake app-server exercises both approval request types", function()
  local files = real_server_fixture("file-approval")
  files.session:start()
  h.truthy(h.wait_for(function() return files.session.state == "idle" end, 2000))
  files.session:send("Edit")
  h.truthy(h.wait_for(function() return files.review.refresh_count == 1 end, 2000))
  h.eq("idle", files.session.state)
  close_real_fixture(files)

  local commands = real_server_fixture("command-approval")
  commands.session:start()
  h.truthy(h.wait_for(function() return commands.session.state == "idle" end, 2000))
  commands.session:send("Test")
  h.truthy(h.wait_for(function()
    return commands.session.state == "waiting_for_command_approval"
  end, 2000))
  local request_id = commands.session.transcript[#commands.session.transcript].request_id
  h.truthy(commands.session:approve_command(request_id, "accept"))
  h.truthy(h.wait_for(function() return commands.review.refresh_count == 1 end, 2000))
  h.eq("idle", commands.session.state)
  close_real_fixture(commands)
end)

h.test("fake app-server reports unsupported sandbox without a weaker retry", function()
  local fixture = real_server_fixture("unsupported-sandbox")
  fixture.session:start()
  h.truthy(h.wait_for(function() return fixture.session.state == "idle" end, 2000))
  local captured

  fixture.session:send("Try", function(err) captured = err end)

  h.truthy(h.wait_for(function() return captured ~= nil end, 2000))
  h.eq("Codex CLI is too old for aichatter.nvim; upgrade Codex and retry.", captured.message)
  h.eq("failed", fixture.session.state)
  close_real_fixture(fixture)
end)

h.test("fake app-server refreshes proposals after a failed turn", function()
  local fixture = real_server_fixture("failed-turn", {
    files = { { path = "main.lua", status = "pending" } },
  })
  fixture.session:start()
  h.truthy(h.wait_for(function() return fixture.session.state == "idle" end, 2000))

  fixture.session:send("Fail after editing")

  h.truthy(h.wait_for(function() return fixture.review.refresh_count == 1 end, 2000))
  h.eq("reviewable", fixture.session.state)
  close_real_fixture(fixture)
end)

h.test("fake app-server crash-once restarts against the same workspace", function()
  local fixture = real_server_fixture("crash-once")
  fixture.session:start()
  h.truthy(h.wait_for(function() return fixture.session.state == "idle" end, 2000))
  local review, shadow, transcript = fixture.session.review, fixture.session.shadow,
    fixture.session.transcript

  fixture.session:send("Crash")

  h.truthy(h.wait_for(function()
    return fixture.session.state == "idle" and fixture.session.restart_attempted
  end, 3000))
  h.eq(review, fixture.session.review)
  h.eq(shadow, fixture.session.shadow)
  h.eq(transcript, fixture.session.transcript)
  close_real_fixture(fixture)
end)
