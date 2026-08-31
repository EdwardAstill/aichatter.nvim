local h = require("tests.helpers")
local Transport = require("aichatter.transport")

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
  transport:stop()
end)
