local h = require("tests.helpers")
local Auth = require("aichatter.auth")

h.test("reuses an existing ChatGPT account", function()
  local transport = h.fake_transport({
    ["account/read"] = { account = { type = "chatgpt" }, requiresOpenaiAuth = true },
  })
  local state

  Auth.new(transport):check(function(err, value)
    h.eq(nil, err)
    state = value
  end)

  h.truthy(state.authenticated)
  h.eq("chatgpt", state.account.type)
  h.truthy(state.requires_openai_auth)
end)

h.test("opens the managed login URL and waits for its completion", function()
  local opened, completed
  local transport = h.fake_transport({
    ["account/login/start"] = {
      type = "chatgpt", loginId = "login-1", authUrl = "https://chatgpt.com/auth",
    },
  })
  local auth = Auth.new(transport, { open_url = function(url) opened = url end })

  auth:login(function(err, value)
    h.eq(nil, err)
    completed = value
  end)

  h.eq("https://chatgpt.com/auth", opened)
  transport:emit("account/login/completed", { loginId = "other-login", success = true })
  h.eq(nil, completed)
  transport:emit("account/login/completed", { loginId = "login-1", success = true })
  h.truthy(completed.success)
end)

h.test("completes a login only once after duplicate notifications", function()
  local calls = 0
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, { open_url = function() end })

  auth:login(function(err)
    h.eq(nil, err)
    calls = calls + 1
  end)
  transport:emit("account/login/completed", { loginId = "login-1", success = true })
  transport:emit("account/login/completed", { loginId = "login-1", success = true })

  h.eq(1, calls)
end)

h.test("rejects a concurrent login without disrupting the active login", function()
  local first, second
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, { open_url = function() end })

  auth:login(function(err, value) first = { err = err, value = value } end)
  auth:login(function(err, value) second = { err = err, value = value } end)
  transport:emit("account/login/completed", { loginId = "login-1", success = true })

  h.matches("already in progress", second.err.message)
  h.eq(nil, first.err)
  h.truthy(first.value.success)
end)

h.test("reports a browser-open error and ignores later completion", function()
  local calls, login_error = 0
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, {
    open_url = function()
      error("browser unavailable")
    end,
  })

  auth:login(function(err)
    calls = calls + 1
    login_error = err
  end)
  transport:emit("account/login/completed", { loginId = "login-1", success = true })

  h.eq(1, calls)
  h.matches("browser unavailable", login_error.message)
end)

h.test("reports a failed browser-open result", function()
  local login_error
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, {
    open_url = function()
      return false, "browser unavailable"
    end,
  })

  auth:login(function(err)
    login_error = err
  end)

  h.matches("browser unavailable", login_error.message)
end)

h.test("cleans up after a cancelled login", function()
  local calls, login_error = 0
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, { open_url = function() end })

  auth:login(function(err)
    calls = calls + 1
    login_error = err
  end)
  transport:emit("account/login/completed", { loginId = "login-1", success = false, error = "cancelled" })
  transport:emit("account/login/completed", { loginId = "login-1", success = true })

  h.eq(1, calls)
  h.eq("cancelled", login_error.message)
end)

h.test("cleans up an in-flight login when the transport exits", function()
  local calls, login_error = 0
  local transport = h.fake_transport({
    ["account/login/start"] = { loginId = "login-1", authUrl = "https://chatgpt.com/auth" },
  })
  local auth = Auth.new(transport, { open_url = function() end })

  auth:login(function(err)
    calls = calls + 1
    login_error = err
  end)
  transport:emit("exit", { code = 1 })
  transport:emit("account/login/completed", { loginId = "login-1", success = true })

  h.eq(1, calls)
  h.matches("transport exited", login_error.message)
end)
