local h = require("tests.helpers")
local Transport = require("aichatter.transport")

local function injected_transport()
  local launched
  local writes = {}
  local process = {
    is_closing = function() return false end,
    write = function(_, value) writes[#writes + 1] = value end,
  }
  local transport = Transport.new({
    cmd = { "this-command-must-not-run" },
    launcher = function(cmd, opts, on_exit)
      launched = { cmd = cmd, opts = opts, on_exit = on_exit }
      return process
    end,
    scheduler = function(callback) callback() end,
  })
  transport:start(function(err) h.eq(nil, err) end)
  launched.opts.stdout(nil, '{"id":1,"result":{}}\n')
  return transport, launched, writes
end

h.test("uses an injected process launcher and scheduler", function()
  local launched
  local writes = {}
  local process = {
    is_closing = function()
      return false
    end,
    write = function(_, value)
      writes[#writes + 1] = value
    end,
  }
  local transport = Transport.new({
    cmd = { "this-command-must-not-run" },
    launcher = function(cmd, opts, on_exit)
      launched = { cmd = cmd, opts = opts, on_exit = on_exit }
      return process
    end,
    scheduler = function(callback)
      callback()
    end,
  })
  local started

  transport:start(function(err)
    started = err
  end)

  h.eq("this-command-must-not-run", launched.cmd[1])
  local initialize = vim.json.decode(writes[1])
  h.eq("initialize", initialize.method)
  h.eq({
    clientInfo = { name = "aichatter.nvim", version = "0.1.0" },
    capabilities = { experimentalApi = true },
  }, initialize.params)
  launched.opts.stdout(nil, '{"id":1,"result":{}}\n')
  h.eq(nil, started)
  h.eq("initialized", vim.json.decode(writes[2]).method)
end)

h.test("reports malformed JSON and keeps parsing following frames", function()
  local transport, launched = injected_transport()
  local diagnostics = {}
  local result
  transport:on("error", function(err)
    diagnostics[#diagnostics + 1] = err
  end)
  transport:request("account/read", {}, function(err, value)
    h.eq(nil, err)
    result = value
  end)

  launched.opts.stdout(nil, 'not-json\n{"id":2,"result":{"ok":true}}\n')

  h.eq("malformed_json", diagnostics[1].code)
  h.matches("malformed JSON", diagnostics[1].message)
  h.eq(true, result.ok)
end)

h.test("reports unknown responses and notifications as diagnostics", function()
  local transport, launched = injected_transport()
  local diagnostics = {}
  transport:on("error", function(err)
    diagnostics[#diagnostics + 1] = err
  end)

  launched.opts.stdout(nil, '{"id":99,"result":{}}\n')
  launched.opts.stdout(nil, '{"method":"mystery/event","params":{"value":1}}\n')

  h.eq("unknown_response", diagnostics[1].code)
  h.eq(99, diagnostics[1].id)
  h.eq("unknown_notification", diagnostics[2].code)
  h.eq("mystery/event", diagnostics[2].method)
end)

h.test("protects listener dispatch and reports thrown listener diagnostics", function()
  local transport, launched = injected_transport()
  local diagnostics = {}
  local delivered = 0
  transport:on("error", function(err)
    diagnostics[#diagnostics + 1] = err
  end)
  transport:on("item/agentMessage/delta", function()
    error("listener exploded")
  end)
  transport:on("item/agentMessage/delta", function(params)
    delivered = delivered + #(params.delta or "")
  end)

  launched.opts.stdout(nil,
    '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n')

  h.eq(2, delivered)
  h.eq("listener_error", diagnostics[1].code)
  h.eq("item/agentMessage/delta", diagnostics[1].method)
  h.matches("listener exploded", diagnostics[1].message)
end)

h.test("initializes and correlates responses from a real child process", function()
  local transport = Transport.new({
    cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l",
      "tests/fixtures/fake_app_server.lua", "initialize" },
  })
  local results = {}

  transport:start(function(err)
    h.eq(nil, err)
    local first = transport:request("account/read", { refreshToken = false }, function(req_err, value)
      h.eq(nil, req_err)
      results.first = value
    end)
    local second = transport:request("account/read", { refreshToken = true }, function(req_err, value)
      h.eq(nil, req_err)
      results.second = value
    end)
    h.eq(2, first)
    h.eq(3, second)
  end)

  h.truthy(h.wait_for(function()
    return results.first ~= nil and results.second ~= nil
  end, 2000))
  h.eq("chatgpt", results.first.account.type)
  h.eq(false, results.first.refreshToken)
  h.eq(true, results.second.refreshToken)
  local stopped = false
  transport:stop(function()
    stopped = true
  end)
  h.truthy(h.wait_for(function()
    return stopped
  end, 2000))
  h.truthy(transport.exited)
end)

h.test("waits for child exit and rejects pending requests when stopped", function()
  local transport = Transport.new({
    cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l",
      "tests/fixtures/fake_app_server.lua", "initialize" },
  })
  local request_error
  local stopped = false
  local stop_error

  transport:start(function(err)
    h.eq(nil, err)
    transport:request("never/respond", {}, function(req_err)
      request_error = req_err
    end)
    transport:stop(function(stop_err)
      stop_error = stop_err
      stopped = true
    end)
  end)

  h.truthy(h.wait_for(function()
    return stopped and request_error ~= nil
  end, 2000))
  h.eq("transport stopped", request_error.message)
  h.eq(nil, stop_error)
  h.truthy(transport.exited)
end)

h.test("emits an exit event when the app server ends", function()
  local launched
  local process = {
    is_closing = function()
      return false
    end,
    write = function() end,
  }
  local transport = Transport.new({
    launcher = function(_, opts, on_exit)
      launched = { opts = opts, on_exit = on_exit }
      return process
    end,
    scheduler = function(callback)
      callback()
    end,
  })
  local exited

  transport:start(function(err)
    h.eq(nil, err)
  end)
  launched.opts.stdout(nil, '{"id":1,"result":{}}\n')
  transport:on("exit", function(result)
    exited = result
  end)
  launched.on_exit({ code = 23, signal = 0 })

  h.eq(23, exited.code)
  h.eq(0, exited.signal)
end)

h.test("can initialize a fresh process after an unexpected exit", function()
  local launches = {}
  local transport = Transport.new({
    launcher = function(_, opts, on_exit)
      local process = {
        is_closing = function() return false end,
        write = function(_, value)
          launches[#launches].writes[#launches[#launches].writes + 1] = value
        end,
      }
      launches[#launches + 1] = {
        opts = opts,
        on_exit = on_exit,
        process = process,
        writes = {},
      }
      return process
    end,
    scheduler = function(callback) callback() end,
  })
  local starts = 0

  transport:start(function(err)
    h.eq(nil, err)
    starts = starts + 1
  end)
  launches[1].opts.stdout(nil, '{"id":1,"result":{}}\n')
  launches[1].on_exit({ code = 23, signal = 0 })
  transport:start(function(err)
    h.eq(nil, err)
    starts = starts + 1
  end)

  h.eq(2, #launches)
  h.eq("initialize", vim.json.decode(launches[2].writes[1]).method)
  launches[2].opts.stdout(nil, '{"id":2,"result":{}}\n')
  h.eq(2, starts)
end)
