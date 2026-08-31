local M = {}
local commands_registered = false
local instance

local function error_message(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

local function notify_error(err)
  vim.notify(error_message(err), vim.log.levels.ERROR, { title = "aichatter.nvim" })
end

local function protected(callback)
  return function(...)
    local args = { ... }
    local ok, err = xpcall(function() return callback(unpack(args)) end, debug.traceback)
    if not ok then notify_error(err) end
  end
end

local function create_instance()
  if instance then return instance end
  local path = require("aichatter.path")
  local cwd = assert((vim.uv or vim.loop).cwd())
  local session = require("aichatter.session").new({ root = path.project_root(cwd) })
  local ui = require("aichatter.ui").new(session, {})
  instance = { session = session, ui = ui }
  return instance
end

local function start(active, callback)
  if active.session.state ~= "closed" then
    callback()
    return
  end
  active.session:start(function(err)
    if err then notify_error(err) end
    callback(err)
  end)
end

local function with_context(callback)
  local active = create_instance()
  active.ui:open()
  start(active, function(err)
    if err then return end
    if not active.session.context then
      notify_error("AI Chatter context is unavailable; sign in and wait for startup to finish")
      return
    end
    local ok, action_err = xpcall(function() callback(active) end, debug.traceback)
    if not ok then notify_error(action_err) end
  end)
end

local function regular_file(root, value)
  local path = require("aichatter.path")
  local absolute = path.normalize(value, root)
  if absolute == root or not path.is_within(root, absolute) then
    error("context path is outside project root", 0)
  end
  local uv = vim.uv or vim.loop
  local current = root
  local relative = path.relative(root, absolute)
  local components = {}
  for component in relative:gmatch("[^/]+") do
    components[#components + 1] = component
  end
  for index, component in ipairs(components) do
    current = current .. "/" .. component
    local stat = uv.fs_lstat(current)
    if stat and stat.type == "link" then
      error("context path traverses a symlink: " .. value, 0)
    end
    local expected = index == #components and "file" or "directory"
    if not stat or stat.type ~= expected then
      error("context path is not a regular project file: " .. value, 0)
    end
  end
  return absolute
end

local function project_files(root)
  local uv = vim.uv or vim.loop
  local path = require("aichatter.path")
  local result = {}
  local function scan(directory)
    local handle, err = uv.fs_scandir(directory)
    if not handle then error(err or "could not list " .. directory, 0) end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if name ~= ".git" then
        local absolute = directory .. "/" .. name
        if kind == "directory" then
          scan(absolute)
        elseif kind == "file" then
          result[#result + 1] = path.relative(root, absolute)
        end
      end
    end
  end
  scan(root)
  table.sort(result)
  return result
end

function M.setup(opts)
  return require("aichatter.config").setup(opts)
end

function M.toggle()
  local active = create_instance()
  active.ui:toggle()
  start(active, function() end)
end

function M.login()
  local active = create_instance()
  active.ui:open()
  start(active, function(err)
    if err then return end
    if active.session.state ~= "auth_required" then
      if active.session.state ~= "idle" and active.session.state ~= "reviewable" then
        notify_error("AI Chatter login is unavailable while the session is " .. active.session.state)
      end
      return
    end
    active.session:login(function(login_err)
      if login_err then notify_error(login_err) end
    end)
  end)
end

function M.add_file(value)
  with_context(function(active)
    local root = active.session.context.root
    local function add(selected)
      if not selected or selected == "" then return end
      active.session.context:add_file(regular_file(root, selected))
      active.ui:render()
    end
    if value and value ~= "" then
      add(value)
      return
    end
    vim.ui.select(project_files(root), {
      prompt = "Add project file to AI Chatter",
    }, protected(function(selected)
      if instance ~= active or active.session.disposed then return end
      add(selected)
    end))
  end)
end

function M.add_selection(command)
  command = command or {}
  with_context(function(active)
    local first, last = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local ranged = (command.range or 0) > 0
    local bufnr = ranged and command.bufnr
      or (first[1] ~= 0 and first[1] or vim.api.nvim_get_current_buf())
    local last_bufnr = ranged and bufnr or (last[1] ~= 0 and last[1] or bufnr)
    local first_line = ranged and command.line1 or first[2]
    local last_line = ranged and command.line2 or last[2]
    if bufnr ~= last_bufnr or not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
        or first_line < 1 or last_line < first_line then
      error("AIChatAddSelection requires valid visual marks in one buffer", 0)
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then error("selected buffer must have a project file name", 0) end
    local lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false)
    active.session.context:add_selection(name, first_line, last_line, lines)
    active.ui:render()
  end)
end

function M.cancel()
  if not instance then
    notify_error("AI Chatter has no active turn to cancel")
    return
  end
  instance.session:cancel(function(err)
    if err then notify_error(err) end
  end)
end

function M.close()
  local active = instance
  if not active then return end
  local function discard()
    active.session:close(function(err)
      if err then notify_error(err) end
      active.ui:close()
      if instance == active then instance = nil end
    end)
  end
  local review = active.session.review
  local files = review and type(review.files) == "function" and review:files() or {}
  if #files == 0 then
    discard()
    return
  end
  vim.ui.select({ "Keep reviewing", "Discard pending changes" }, {
    prompt = "AI Chatter has pending changes",
  }, protected(function(choice)
    if choice == "Discard pending changes" and instance == active then discard() end
  end))
end

function M._register_commands()
  if commands_registered then return end
  commands_registered = true
  vim.api.nvim_create_user_command("AIChat", protected(function() M.toggle() end), {
    desc = "Toggle the AI Chatter sidebar",
  })
  vim.api.nvim_create_user_command("AIChatLogin", protected(function() M.login() end), {
    desc = "Sign in to Codex with ChatGPT",
  })
  vim.api.nvim_create_user_command("AIChatAddFile", protected(function(command)
    M.add_file(command.args)
  end), {
    nargs = "?",
    complete = "file",
    desc = "Add a project file to AI Chatter context",
  })
  vim.api.nvim_create_user_command("AIChatAddSelection", protected(function(command)
    command.bufnr = vim.api.nvim_get_current_buf()
    M.add_selection(command)
  end), {
    range = true,
    desc = "Add the last visual selection to AI Chatter context",
  })
  vim.api.nvim_create_user_command("AIChatCancel", protected(function() M.cancel() end), {
    desc = "Cancel the active AI Chatter turn",
  })
  vim.api.nvim_create_user_command("AIChatClose", protected(function() M.close() end), {
    desc = "Close AI Chatter and discard its shadow workspace",
  })
end

return M
