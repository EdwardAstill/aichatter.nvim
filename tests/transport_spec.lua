local h = require("tests.helpers")
local Transport = require("aichatter.transport")

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
  h.eq("initialize", vim.json.decode(writes[1]).method)
  launched.opts.stdout(nil, '{"id":1,"result":{}}\n')
  h.eq(nil, started)
  h.eq("initialized", vim.json.decode(writes[2]).method)
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
