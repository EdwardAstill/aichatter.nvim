local Auth = {}
Auth.__index = Auth

local function noop() end

function Auth.new(transport, opts)
  opts = opts or {}

  return setmetatable({
    transport = transport,
    open_url = opts.open_url or vim.ui.open,
  }, Auth)
end

function Auth:check(callback)
  self.transport:request("account/read", { refreshToken = false }, function(err, result)
    if err then
      callback(err)
      return
    end

    callback(nil, {
      authenticated = result.account ~= nil,
      account = result.account,
      requires_openai_auth = result.requiresOpenaiAuth,
    })
  end)
end

function Auth:_finish_login(state, err, result)
  if self.login_state ~= state or state.finished then
    return
  end

  state.finished = true
  self.login_state = nil
  self.transport:off("account/login/completed", state.completion_listener)
  self.transport:off("exit", state.exit_listener)
  state.callback(err, result)
end

function Auth:login(callback)
  callback = callback or noop
  if self.login_state then
    callback({ message = "login already in progress" })
    return
  end

  local state = { callback = callback }
  self.login_state = state

  self.transport:request("account/login/start", {
    type = "chatgpt",
    useHostedLoginSuccessPage = true,
    appBrand = "codex",
  }, function(err, result)
    if self.login_state ~= state then
      return
    end

    if err then
      self:_finish_login(state, err)
      return
    end

    state.completion_listener = function(params)
      if not params or params.loginId ~= result.loginId then
        return
      end

      local login_err
      if not params.success then
        login_err = { message = params.error or "login cancelled" }
      end
      self:_finish_login(state, login_err, params)
    end
    state.exit_listener = function()
      self:_finish_login(state, { message = "transport exited during login" })
    end
    self.transport:on("account/login/completed", state.completion_listener)
    self.transport:on("exit", state.exit_listener)

    local opened, open_result, open_err = pcall(self.open_url, result.authUrl)
    if not opened then
      self:_finish_login(state, { message = open_result })
    elseif open_result == false then
      self:_finish_login(state, { message = open_err or "failed to open login URL" })
    end
  end)
end

return Auth
