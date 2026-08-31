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

h.test("keeps unhandled server notifications out of the error transcript", function()
  local fixture = h.session_fixture({ files = {} })

  fixture.transport:emit("error", {
    code = "unknown_notification",
    message = "received notification for an unknown method",
    method = "remoteControl/status/changed",
    params = { status = "disabled" },
  })

  h.eq({}, fixture.session.transcript)
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

h.test("inherits the thread permission profile instead of overriding turn sandbox reads", function()
  local fixture = h.session_fixture()

  fixture.session:send("Edit safely")

  h.eq({
    threadId = "thread-1",
    input = { { type = "text", text = "Edit safely" } },
  }, requests(fixture.transport, "turn/start")[1].params)
end)

h.test("lists picker-visible Codex models", function()
  local fixture = h.session_fixture({
    responses = {
      ["model/list"] = {
        data = {
          {
            id = "gpt-5.6-sol",
            model = "gpt-5.6-sol",
            displayName = "GPT-5.6-Sol",
            hidden = false,
            defaultReasoningEffort = "low",
            supportedReasoningEfforts = {
              { reasoningEffort = "low", description = "Fast responses" },
            },
            inputModalities = { "text", "image" },
            supportsPersonality = true,
            isDefault = true,
          },
        },
        nextCursor = vim.NIL,
      },
    },
  })
  h.truthy(type(fixture.session.list_models) == "function")
  local models

  fixture.session:list_models(function(err, value)
    h.eq(nil, err)
    models = value
  end)

  h.eq("gpt-5.6-sol", models[1].id)
  h.eq({ limit = 100, includeHidden = false },
    requests(fixture.transport, "model/list")[1].params)
end)

h.test("applies a selected model to future turns", function()
  local fixture = h.session_fixture({ files = {} })
  h.truthy(type(fixture.session.select_model) == "function")

  fixture.session:select_model("gpt-5.6-terra")
  fixture.session:send("Use the selected model")

  h.eq("gpt-5.6-terra", fixture.session.model)
  h.eq("gpt-5.6-terra", requests(fixture.transport, "turn/start")[1].params.model)
  h.eq("model", fixture.events[1].name)
  h.eq("gpt-5.6-terra", fixture.events[1].value)
end)

h.test("uses supported reasoning effort and resets it for a different model", function()
  local fixture = h.session_fixture({
    files = {},
    responses = {
      ["model/list"] = {
        data = {
          {
            id = "gpt-5.6-sol",
            model = "gpt-5.6-sol",
            displayName = "GPT-5.6-Sol",
            hidden = false,
            defaultReasoningEffort = "low",
            supportedReasoningEfforts = {
              { reasoningEffort = "low", description = "Fast responses" },
              { reasoningEffort = "high", description = "Deeper reasoning" },
            },
            inputModalities = { "text", "image" },
            supportsPersonality = true,
            isDefault = true,
          },
          {
            id = "gpt-5.6-terra",
            model = "gpt-5.6-terra",
            displayName = "GPT-5.6-Terra",
            hidden = false,
            defaultReasoningEffort = "medium",
            supportedReasoningEfforts = {
              { reasoningEffort = "medium", description = "Balanced reasoning" },
            },
            inputModalities = { "text", "image" },
            supportsPersonality = true,
            isDefault = false,
          },
        },
        nextCursor = vim.NIL,
      },
    },
  })
  fixture.session.model = "gpt-5.6-sol"
  fixture.session:list_models(function(err) h.eq(nil, err) end)

  h.eq("low", fixture.session.reasoning_effort)
  local ok, err = fixture.session:select_reasoning("high")
  h.truthy(ok)
  h.eq(nil, err)
  fixture.session:send("Think harder")
  h.eq("high", requests(fixture.transport, "turn/start")[1].params.effort)

  fixture.session:select_model("gpt-5.6-terra")
  h.eq("medium", fixture.session.reasoning_effort)
  ok, err = fixture.session:select_reasoning("high")
  h.falsy(ok)
  h.matches("not supported", err.message)
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

  fixture.session:send("Edit safely")
  fixture.transport:server_request(41, "item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "f1",
    grantRoot = "/shadow/workspace",
  })
  h.eq("acceptForSession", fixture.transport.responses[41].result.decision)

  fixture.transport:server_request(42, "item/commandExecution/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    command = { "make", "test" },
  })
  h.eq("waiting_for_command_approval", fixture.session.state)
  h.eq(nil, fixture.transport.responses[42])

  fixture.session:approve_command(42, "decline")
  h.eq("decline", fixture.transport.responses[42].result.decision)
  h.eq("running", fixture.session.state)
end)

h.test("explicitly declines file approvals without a disposable active turn", function()
  local transport = h.fake_transport({})
  Session.new({ transport = transport, emit = function() end })

  transport:server_request(7, "item/fileChange/requestApproval", { itemId = "f1" })

  h.eq("decline", transport.responses[7].result.decision)
end)

h.test("explicitly declines stale and external file approvals", function()
  local fixture = h.session_fixture()
  fixture.session:send("Edit safely")

  fixture.transport:server_request(8, "item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-stale",
    itemId = "f1",
    grantRoot = "/project",
  })
  fixture.transport:server_request(9, "item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "f2",
    grantRoot = "/project",
  })

  h.eq("decline", fixture.transport.responses[8].result.decision)
  h.eq("decline", fixture.transport.responses[9].result.decision)
end)

h.test("declines a grant that traverses a symlink inside the shadow", function()
  local workspace = h.tempdir()
  local outside = h.tempdir()
  h.mkdir(workspace .. "/safe")
  h.symlink(outside, workspace .. "/escape")
  local fixture = h.session_fixture({
    shadow = {
      project_root = h.tempdir(),
      baseline_root = workspace .. "/../baseline",
      workspace_root = workspace,
      cleanup = function(_, callback) callback() end,
    },
  })
  fixture.session:send("Edit safely")

  fixture.transport:server_request(10, "item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "safe",
    grantRoot = workspace .. "/safe",
  })
  fixture.transport:server_request(11, "item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "escape",
    grantRoot = workspace .. "/escape/child",
  })

  h.eq("acceptForSession", fixture.transport.responses[10].result.decision)
  h.eq("decline", fixture.transport.responses[11].result.decision)
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
  local files = { { path = "main.lua", status = "conflict" } }
  local review = {
    refresh = function(_, callback) callback() end,
    files = function() return files end,
    sync_live = function(_, callback)
      callback({ code = "conflict", paths = { "a.lua", "b.lua" } })
    end,
  }
  local fixture = h.session_fixture({ review = review })
  local calls, send_error = 0

  fixture.session:send("Continue", function(err)
    calls = calls + 1
    send_error = err
  end)

  h.eq(1, calls)
  h.eq("conflict", send_error.code)
  h.eq("reviewable", fixture.session.state)
  h.eq(0, #requests(fixture.transport, "turn/start"))
  h.eq("conflict", fixture.events[1].name)
  h.eq({ "a.lua", "b.lua" }, fixture.events[1].value.paths)
end)

h.test("fails with the exact upgrade diagnostic without retrying a rejected turn", function()
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
  h.eq(nil, requests(fixture.transport, "turn/start")[1].params.sandboxPolicy)
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
    approvalPolicy = "never",
    permissions = ":danger-full-access",
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
  local fixture = h.session_fixture({ files = {} })
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

h.test("refreshes crash partial edits before recovery becomes reviewable", function()
  local files = {}
  local review = {
    refresh_count = 0,
    sync_count = 0,
    refresh = function(self, callback)
      self.refresh_count = self.refresh_count + 1
      files = { { path = "partial.lua", status = "pending" } }
      callback()
    end,
    sync_live = function(self, callback)
      self.sync_count = self.sync_count + 1
      callback()
    end,
    files = function() return files end,
  }
  local fixture = h.session_fixture({ review = review, files = files })
  fixture.session:send("write then crash")

  fixture.transport:emit("exit", { code = 23 })

  h.eq(1, review.refresh_count)
  h.eq("reviewable", fixture.session.state)
  h.eq(fixture.shadow.workspace_root,
    requests(fixture.transport, "thread/start")[1].params.cwd)
  local followup_error
  fixture.session:send("continue from partial", function(err) followup_error = err end)
  h.eq(nil, followup_error)
  h.eq("running", fixture.session.state)
end)

h.test("serializes review actions and reconciles an empty queue to idle", function()
  local callbacks = {}
  local calls = {}
  local files = { { path = "main.lua", status = "pending" } }
  local review = {
    refresh = function(_, callback) callback() end,
    sync_live = function(_, callback) callback() end,
    files = function() return files end,
    accept_file = function(_, path, callback)
      calls[#calls + 1] = "accept:" .. path
      callbacks[#callbacks + 1] = function()
        files = {}
        callback()
      end
    end,
    reject_file = function(_, path, callback)
      calls[#calls + 1] = "reject:" .. path
      callbacks[#callbacks + 1] = callback
    end,
  }
  local fixture = h.session_fixture({ review = review, state = "reviewable" })
  local completed = 0

  h.truthy(fixture.session:review_action("accept_file", "main.lua", function(err)
    h.eq(nil, err)
    completed = completed + 1
  end))
  h.truthy(fixture.session:review_action("reject_file", "main.lua", function(err)
    h.eq(nil, err)
    completed = completed + 1
  end))
  h.eq({ "accept:main.lua" }, calls)
  callbacks[1]()
  h.eq({ "accept:main.lua", "reject:main.lua" }, calls)
  callbacks[2]()

  h.eq(2, completed)
  h.eq("idle", fixture.session.state)
end)

h.test("gates review actions while a turn or send synchronization is active", function()
  local fixture = h.session_fixture()
  fixture.session:send("running")
  local err

  local accepted = fixture.session:review_action("accept_file", "main.lua", function(value)
    err = value
  end)

  h.falsy(accepted)
  h.eq("invalid_state", err.code)
end)

h.test("close joins an active review mutation before shadow cleanup", function()
  local mutation_callback
  local review = {
    refresh = function(_, callback) callback() end,
    sync_live = function(_, callback) callback() end,
    files = function() return { { path = "main.lua", status = "pending" } } end,
    accept_file = function(_, _, callback) mutation_callback = callback end,
  }
  local fixture = h.session_fixture({ review = review, state = "reviewable" })
  local review_error, closed = nil, false
  fixture.session:review_action("accept_file", "main.lua", function(err) review_error = err end)

  fixture.session:close(function() closed = true end)

  h.eq(0, fixture.shadow.cleanup_count)
  h.falsy(closed)
  mutation_callback()
  h.eq(nil, review_error)
  h.eq(1, fixture.shadow.cleanup_count)
  h.truthy(closed)
  h.eq("closed", fixture.session.state)
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

h.test("close settles a send before a delayed live sync returns", function()
  local sync_callback
  local review = {
    refresh = function(_, callback) callback() end,
    files = function() return {} end,
    sync_live = function(_, callback) sync_callback = callback end,
  }
  local fixture = h.session_fixture({ review = review, files = {} })
  local calls, send_error = 0
  fixture.session:send("Wait", function(err)
    calls = calls + 1
    send_error = err
  end)

  fixture.session:close()

  h.eq(1, calls)
  h.matches("clos", send_error.message)
  h.eq("closed", fixture.session.state)
  sync_callback()
  h.eq(1, calls)
  h.eq(0, #requests(fixture.transport, "turn/start"))
end)

h.test("close rejects reentrant work and joins a reentrant close once", function()
  local sync_callback
  local review = {
    refresh = function(_, callback) callback() end,
    files = function() return {} end,
    sync_live = function(_, callback) sync_callback = callback end,
  }
  local fixture = h.session_fixture({ review = review, files = {} })
  local cleanup_count = 0
  fixture.session.shadow.cleanup = function(_, callback)
    cleanup_count = cleanup_count + 1
    callback()
  end
  local send_calls, reentrant_send_calls = 0, 0
  local joined_close_calls, outer_close_calls = 0, 0
  fixture.session:send("Wait", function(err)
    h.matches("clos", err.message)
    send_calls = send_calls + 1
    fixture.session:close(function(close_err)
      h.eq(nil, close_err)
      joined_close_calls = joined_close_calls + 1
    end)
    fixture.session:send("Re-enter", function(reentrant_err)
      h.truthy(reentrant_err)
      reentrant_send_calls = reentrant_send_calls + 1
    end)
  end)

  local ok = pcall(function()
    fixture.session:close(function(err)
      h.eq(nil, err)
      outer_close_calls = outer_close_calls + 1
    end)
  end)

  h.truthy(ok)
  h.eq(1, send_calls)
  h.eq(1, reentrant_send_calls)
  h.eq(1, joined_close_calls)
  h.eq(1, outer_close_calls)
  h.eq(1, fixture.transport.stops)
  h.eq(1, cleanup_count)
  h.eq("closed", fixture.session.state)
  sync_callback()
  h.eq(1, send_calls)
  h.eq(1, reentrant_send_calls)
end)

h.test("exit rejects callback re-entry before beginning recovery", function()
  local sync_callbacks = {}
  local review = {
    refresh = function(_, callback) callback() end,
    files = function() return {} end,
    sync_live = function(_, callback)
      sync_callbacks[#sync_callbacks + 1] = callback
    end,
  }
  local fixture = h.session_fixture({ review = review, files = {} })
  local send_calls, reentrant_calls = 0, 0
  fixture.session:send("Wait", function(err)
    h.matches("exit", err.message)
    send_calls = send_calls + 1
    fixture.session:send("Re-enter", function(reentrant_err)
      h.truthy(reentrant_err)
      reentrant_calls = reentrant_calls + 1
    end)
  end)

  fixture.transport:emit("exit", { code = 23 })

  h.eq(1, send_calls)
  h.eq(1, reentrant_calls)
  h.eq(1, #sync_callbacks)
  h.eq("idle", fixture.session.state)
  h.eq(1, fixture.transport.starts)
  sync_callbacks[1]()
  h.eq(0, #requests(fixture.transport, "turn/start"))
end)

h.test("ignores a stale completion refresh and waits for the crash refresh", function()
  local refresh_callbacks = {}
  local review = {
    refresh_count = 0,
    sync_live = function(_, callback) callback() end,
    refresh = function(self, callback)
      self.refresh_count = self.refresh_count + 1
      refresh_callbacks[#refresh_callbacks + 1] = callback
    end,
    files = function() return { { path = "main.lua", status = "pending" } } end,
  }
  local fixture = h.session_fixture({ review = review })
  fixture.session:send("Change")
  fixture.transport:emit("turn/completed", {
    turn = { id = "turn-1", status = "completed" },
  })
  fixture.transport:emit("exit", { code = 23 })

  h.eq(2, #refresh_callbacks)
  h.eq("starting", fixture.session.state)
  h.eq(0, fixture.transport.starts)
  local stale_ok = pcall(refresh_callbacks[1])
  h.eq("starting", fixture.session.state)
  local recovery_ok = pcall(refresh_callbacks[2])

  h.truthy(stale_ok)
  h.truthy(recovery_ok)
  h.eq("reviewable", fixture.session.state)
  h.eq(1, fixture.transport.starts)
end)

h.test("cleans a stale shadow returned after exit and reruns missing prerequisites", function()
  local create_callbacks = {}
  local stale_cleanup = 0
  local start_calls, start_error = 0
  local transport = h.fake_transport({
    ["thread/start"] = { thread = { id = "thread-new" } },
  })
  local auth = {
    check = function(_, callback) callback(nil, { authenticated = true }) end,
  }
  local session = Session.new({
    transport = transport,
    auth = auth,
    root = "/project",
    create_shadow = function(_, callback)
      create_callbacks[#create_callbacks + 1] = callback
    end,
    review_factory = function() return {
      refresh = function(_, callback) callback() end,
      sync_live = function(_, callback) callback() end,
      files = function() return {} end,
    } end,
    emit = function() end,
  })
  session:start(function(err)
    start_calls = start_calls + 1
    start_error = err
  end)

  local emitted = pcall(function() transport:emit("exit", { code = 23 }) end)

  h.truthy(emitted)
  h.eq(1, start_calls)
  h.matches("exited", start_error.message)
  h.eq(2, #create_callbacks)
  create_callbacks[1](nil, {
    project_root = "/project",
    baseline_root = "/stale/control/baseline",
    workspace_root = "/stale/workspace",
    cleanup = function(_, callback)
      stale_cleanup = stale_cleanup + 1
      callback()
    end,
  })
  h.eq(1, stale_cleanup)
  create_callbacks[2](nil, {
    project_root = "/project",
    baseline_root = "/current/control/baseline",
    workspace_root = "/current/workspace",
    cleanup = function(_, callback) callback() end,
  })
  h.eq("idle", session.state)
  h.eq("/current/workspace", session.shadow.workspace_root)
end)

h.test("ignores a delayed restart callback after terminal close", function()
  local restart_callback
  local fixture = h.session_fixture({
    responses = {
      __start = function(_, callback) restart_callback = callback end,
    },
  })

  fixture.transport:emit("exit", { code = 23 })
  fixture.session:close()
  local ok = pcall(restart_callback)

  h.truthy(ok)
  h.eq("closed", fixture.session.state)
  h.eq(0, #requests(fixture.transport, "thread/start"))
end)

h.test("replays matching turn notifications received before start response", function()
  local turn_callback
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback) turn_callback = callback end,
    },
  })
  local send_calls = 0
  fixture.session:send("Early", function(err)
    h.eq(nil, err)
    send_calls = send_calls + 1
  end)
  fixture.transport:emit("item/agentMessage/delta", {
    threadId = "thread-1",
    turnId = "turn-early",
    delta = "before response",
  })
  fixture.transport:emit("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-early", status = "completed" },
  })

  turn_callback(nil, { turn = { id = "turn-early" } })

  h.eq(1, send_calls)
  h.eq("before response", fixture.session.transcript[2].text)
  h.eq(1, fixture.review.refresh_count)
  h.eq("reviewable", fixture.session.state)
  h.eq({ "state", "user", "item/agentMessage/delta", "turn/completed", "state" },
    event_names(fixture.events))
end)

h.test("discards buffered notifications for a different candidate turn", function()
  local turn_callback
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback) turn_callback = callback end,
    },
  })
  fixture.session:send("Early")
  fixture.transport:emit("item/agentMessage/delta", {
    threadId = "thread-1",
    turnId = "turn-other",
    delta = "wrong turn",
  })

  turn_callback(nil, { turn = { id = "turn-right" } })

  h.eq(1, #fixture.session.transcript)
  h.eq("user", fixture.session.transcript[1].type)
  h.eq("running", fixture.session.state)
end)

h.test("discards buffered candidate notifications when turn start fails", function()
  local turn_callback
  local context = Context.new("/project")
  context:add_file("main.lua")
  local fixture = h.session_fixture({
    context = context,
    responses = {
      ["turn/start"] = function(_, callback) turn_callback = callback end,
    },
  })
  fixture.session:send("Early")
  fixture.transport:emit("item/agentMessage/delta", {
    threadId = "thread-1",
    turnId = "turn-early",
    delta = "discard me",
  })

  turn_callback({ message = "turn rejected" })

  h.eq("failed", fixture.session.state)
  h.eq(1, #fixture.session.transcript)
  h.eq("error", fixture.session.transcript[1].type)
  h.eq(2, #context:inputs("Retry"))
end)

h.test("restarts idle and reviewable sessions and fails their second exit", function()
  for _, value in ipairs({ "idle", "reviewable" }) do
    local fixture = h.session_fixture({
      state = value,
      files = value == "reviewable" and { { path = "main.lua" } } or {},
    })

    fixture.transport:emit("exit", { code = 23 })
    h.eq(value, fixture.session.state)
    h.eq(1, fixture.transport.starts)

    fixture.transport:emit("exit", { code = 24 })
    h.eq("failed", fixture.session.state)
    h.eq(1, fixture.transport.starts)
  end
end)

h.test("reinitializes auth without thread-starting when an auth-required server exits", function()
  local checks = 0
  local transport = h.fake_transport({
    ["thread/start"] = { thread = { id = "must-not-start" } },
  })
  local session = Session.new({
    transport = transport,
    auth = {
      check = function(_, callback)
        checks = checks + 1
        callback(nil, { authenticated = false })
      end,
    },
    create_shadow = function() error("shadow must not be created") end,
    emit = function() end,
  })
  session:start()
  h.eq("auth_required", session.state)

  local ok = pcall(function() transport:emit("exit", { code = 23 }) end)

  h.truthy(ok)
  h.eq("auth_required", session.state)
  h.eq(2, checks)
  h.eq(0, #requests(transport, "thread/start"))
end)

h.test("fresh close tears down handlers once and permanently rejects reopen", function()
  local transport = h.fake_transport({})
  local session = Session.new({ transport = transport, emit = function() end })
  local close_calls = 0

  session:close(function(err)
    h.eq(nil, err)
    close_calls = close_calls + 1
  end)
  session:close(function(err)
    h.eq(nil, err)
    close_calls = close_calls + 1
  end)
  local start_error
  session:start(function(err) start_error = err end)

  h.eq(2, close_calls)
  h.eq(1, transport.stops)
  h.eq(0, transport:total_listener_count())
  h.matches("disposed", start_error.message)
  h.eq(0, transport.starts)
end)

h.test("does not infer unsupported v2 fields from nested error payload data", function()
  local original = {
    code = -32602,
    message = "request rejected",
    data = { diagnostic = "unknown field readOnlyAccess" },
  }
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback) callback(original) end,
    },
  })
  local captured

  fixture.session:send("Try", function(err) captured = err end)

  h.eq("request rejected", captured.message)
  h.eq(original.data, captured.data)
end)

h.test("requires an unsupported phrase to name the restricted v2 field", function()
  local original = {
    code = -32602,
    message = "ephemeral=true was accepted; unsupported field executionMode",
  }
  local fixture = h.session_fixture({
    responses = {
      ["turn/start"] = function(_, callback) callback(original) end,
    },
  })
  local captured

  fixture.session:send("Try", function(err) captured = err end)

  h.eq(original.message, captured.message)
end)

h.test("requires exact restricted v2 identifiers in structured errors", function()
  for _, original in ipairs({
    { code = -32602, message = "unknown field ephemeralMode" },
    { code = -32602, message = "unknown field ephemeral_mode" },
    { code = -32602, message = "unsupported readOnlyAccessV2" },
    { code = -32602, message = "unsupported readOnlyAccess-v2" },
    { code = "unknown_field_ephemeralMode", message = "request rejected" },
  }) do
    local fixture = h.session_fixture({
      responses = {
        ["turn/start"] = function(_, callback) callback(original) end,
      },
    })
    local captured

    fixture.session:send("Try", function(err) captured = err end)

    h.eq(original.message, captured.message)
  end
end)

h.test("recognizes direct invalid and unsupported v2 identifiers", function()
  for _, original in ipairs({
    { code = "invalid_parameter_ephemeral", message = "invalid params" },
    { code = -32602, message = "`readOnlyAccess` is not supported" },
  }) do
    local fixture = h.session_fixture({
      responses = {
        ["turn/start"] = function(_, callback) callback(original) end,
      },
    })
    local captured

    fixture.session:send("Try", function(err) captured = err end)

    h.eq("Codex CLI is too old for aichatter.nvim; upgrade Codex and retry.",
      captured.message)
  end
end)

local function pending_command_fixture()
  local fixture = h.session_fixture({ files = {} })
  fixture.session:send("Run")
  fixture.transport:server_request(77, "item/commandExecution/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "command-1",
    command = "make test",
  })
  return fixture, fixture.session.transcript[#fixture.session.transcript]
end

h.test("expires and declines a pending command on turn completion", function()
  local fixture, entry = pending_command_fixture()

  fixture.transport:emit("turn/completed", {
    turn = { id = "turn-1", status = "completed" },
  })

  h.eq("expired", entry.status)
  h.eq("decline", fixture.transport.responses[77].result.decision)
  h.falsy(fixture.session:approve_command(77, "accept"))
end)

h.test("cancels a pending command before interrupting its turn", function()
  local fixture, entry = pending_command_fixture()

  fixture.session:cancel()

  h.eq("cancelled", entry.status)
  h.eq("cancel", fixture.transport.responses[77].result.decision)
  h.falsy(fixture.session:approve_command(77, "accept"))
end)

h.test("fails a pending command without responding after transport exit", function()
  local fixture, entry = pending_command_fixture()

  fixture.transport:emit("exit", { code = 23 })

  h.eq("failed", entry.status)
  h.eq(nil, fixture.transport.responses[77])
  h.falsy(fixture.session:approve_command(77, "accept"))
end)

h.test("cancels a pending command once before close stops transport", function()
  local fixture, entry = pending_command_fixture()

  fixture.session:close()

  h.eq("cancelled", entry.status)
  h.eq("cancel", fixture.transport.responses[77].result.decision)
  h.falsy(fixture.session:approve_command(77, "accept"))
end)

h.test("stops a live failed transport before retrying after a CLI upgrade", function()
  local upgraded = false
  local fixture = h.session_fixture({
    responses = {
      ["account/read"] = { account = { type = "chatgpt" }, requiresOpenaiAuth = true },
      ["thread/start"] = { thread = { id = "thread-upgraded" } },
      ["turn/start"] = function(_, callback)
        if upgraded then
          callback(nil, { turn = { id = "turn-upgraded" } })
        else
          callback({ code = -32602, message = "unknown field readOnlyAccess" })
        end
      end,
    },
  })
  local connected = true
  function fixture.transport:start(callback)
    self.starts = self.starts + 1
    if connected then
      callback({ message = "transport already started" })
    else
      connected = true
      callback()
    end
  end
  function fixture.transport:stop(callback)
    self.stops = self.stops + 1
    connected = false
    callback()
  end
  fixture.session:send("Before upgrade")
  h.eq("failed", fixture.session.state)
  upgraded = true
  local retry_calls, retry_error = 0

  fixture.session:start(function(err)
    retry_calls = retry_calls + 1
    retry_error = err
  end)

  h.eq(nil, retry_error)
  h.eq(1, retry_calls)
  h.eq(1, fixture.transport.stops)
  h.eq(1, fixture.transport.starts)
  h.eq("idle", fixture.session.state)
  fixture.session:send("After upgrade")
  local turns = requests(fixture.transport, "turn/start")
  h.eq(nil, turns[#turns].params.sandboxPolicy)
end)

h.test("fake app-server supports authenticated and account-required startup", function()
  local authenticated = real_server_fixture("authenticated")
  authenticated.session:start()
  h.truthy(h.wait_for(function() return authenticated.session.state == "idle" end, 2000))
  h.eq("gpt-5.6-sol", authenticated.session.model)
  h.eq("low", authenticated.session.reasoning_effort)
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
