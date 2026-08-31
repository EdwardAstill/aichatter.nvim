local Layout = require("aichatter.ui.layout")
local Transcript = require("aichatter.ui.transcript")
local Composer = require("aichatter.ui.composer")
local Changes = require("aichatter.ui.changes")
local Diff = require("aichatter.ui.diff")

local UI = {}
UI.__index = UI

local event_names = {
  "user",
  "item/agentMessage/delta",
  "item/started",
  "item/completed",
  "item/commandExecution/requestApproval",
  "error",
  "conflict",
  "state",
  "turn/completed",
  "restart",
  "restarted",
}

function UI:_active(generation)
  return not self.closed and (generation == nil or generation == self.generation)
end

function UI:_files()
  if not self.session.review or type(self.session.review.files) ~= "function" then return {} end
  return self.session.review:files() or {}
end

function UI:_report_error(err, generation)
  if not err or not self:_active(generation) then return end
  local entries = vim.list_slice(self.session.transcript or {})
  entries[#entries + 1] = { type = "error", error = err }
  self.transcript:render(entries)
end

function UI:_review_action(method, file)
  if not self:_active() then return end
  local review = self.session.review
  if not review or type(review[method]) ~= "function" then return end
  local generation = self.generation
  review[method](review, file.path, function(err)
    if not self:_active(generation) then return end
    self:_report_error(err, generation)
    self:_reconcile_review(generation)
  end)
end

function UI:_reconcile_review(generation)
  if not self:_active(generation) then return end
  if self.diff_view then self.diff_view:reconcile() end
  self:render_changes()
end

function UI:_open_review(file)
  if not self:_active() or not self.layout then return end
  if self.diff_view then self.diff_view:close() end
  local winid = self.layout.main_win
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  vim.api.nvim_set_current_win(winid)
  local ok, value = pcall(Diff.open, self.session.review, file.path, {
    winid = winid,
    mappings = self.opts.mappings,
    notify = self.opts.notify or vim.notify,
    on_change = function()
      if self:_active() then self:render_changes() end
    end,
  })
  if ok then
    self.diff_view = value
  else
    self:_report_error({ message = tostring(value) })
  end
end

function UI:_render_state()
  self.state = self.session.state
  if self.transcript and self.transcript.winid
      and vim.api.nvim_win_is_valid(self.transcript.winid) then
    vim.wo[self.transcript.winid].statusline =
      " AIChatter · " .. tostring(self.state or "closed") .. " "
  end
end

function UI:_command_approval(value)
  local generation = self.generation
  local request_id = value and value.requestId
  if not request_id then return end
  if self.approval_prompts[request_id] then return end
  self.approval_prompts[request_id] = true
  local select = self.opts.ui_select or vim.ui.select
  select({ "Approve once", "Decline" }, {
    prompt = "Codex command requires approval",
  }, function(choice)
    if not self:_active(generation) then return end
    if not choice then
      self.approval_prompts[request_id] = nil
      return
    end
    local decision = choice == "Approve once" and "accept" or "decline"
    local ok, err = self.session:approve_command(request_id, decision)
    if not ok then self:_report_error(err, generation) end
  end)
end

function UI:_reconcile_command_approvals()
  for request_id in pairs(self.session.pending_commands or {}) do
    self:_command_approval({ requestId = request_id })
  end
end

function UI:_make_views()
  self.generation = (self.generation or 0) + 1
  self.approval_prompts = {}
  local generation = self.generation
  local mappings = self.opts.mappings or {}
  self.transcript = Transcript.new({ schedule = self.opts.schedule })
  self.composer = Composer.new({
    mappings = mappings,
    on_submit = self.opts.on_submit or function(text, complete)
      if not self:_active(generation) then return false end
      local state = self.session.state
      if state ~= "idle" and state ~= "reviewable" then return false end
      local finished = false
      self.session:send(text, function(err)
        if finished then return end
        finished = true
        if not self:_active(generation) then return end
        self:_report_error(err, generation)
        complete(not err)
      end)
      return "pending"
    end,
  })
  self.changes = Changes.new({
    mappings = mappings,
    on_open = self.opts.on_open or function(file) self:_open_review(file) end,
    on_accept = self.opts.on_accept or function(file)
      self:_review_action("accept_file", file)
    end,
    on_reject = self.opts.on_reject or function(file)
      self:_review_action("reject_file", file)
    end,
  })
end

function UI:_event(name, value)
  if not self:_active() then return end
  if name == "item/agentMessage/delta" then
    self.transcript:schedule_render(self.session.transcript or {})
  else
    self.transcript:render(self.session.transcript or {})
  end
  self.composer:render(self.session.context or {})
  if name == "state" then
    self:_render_state()
    self:_reconcile_review()
  elseif name == "turn/completed" then
    self:render_changes()
  end
  if name == "item/commandExecution/requestApproval" then
    self:_command_approval(value)
  end
end

function UI:_bind()
  if self.bound then return end
  self.bound = true
  self.handlers = {}
  if type(self.session.on) == "function" and type(self.session.off) == "function" then
    for _, name in ipairs(event_names) do
      local callback = function(value) self:_event(name, value) end
      self.session:on(name, callback)
      self.handlers[#self.handlers + 1] = { name = name, callback = callback }
    end
    return
  end
  self.previous_emit = self.session.emit
  self.emit_wrapper = function(name, value)
    if self.previous_emit then self.previous_emit(name, value) end
    self:_event(name, value)
  end
  self.session.emit = self.emit_wrapper
end

function UI:_unbind()
  if not self.bound then return end
  self.bound = false
  if type(self.session.off) == "function" then
    for _, handler in ipairs(self.handlers or {}) do
      self.session:off(handler.name, handler.callback)
    end
  elseif self.session.emit == self.emit_wrapper then
    self.session.emit = self.previous_emit
  end
  self.handlers = {}
  self.emit_wrapper = nil
end

function UI:render_changes()
  if not self:_active() then return end
  local files = self:_files()
  self.changes:render(files)
  if not self.layout then return end
  if #files == 0 then
    self.layout:hide_changes()
    self.changes.winid = nil
  else
    self.layout:show_changes(#files)
    self.layout:set_changes_height(#files)
    self.changes.winid = self.layout.changes_win
  end
end

function UI:render(generation)
  if not self:_active(generation) then return end
  self.transcript:render(self.session.transcript or {})
  self.composer:render(self.session.context or {})
  self:render_changes()
end

function UI:open()
  if self.layout and not self.layout.closed then
    if self.composer.winid and vim.api.nvim_win_is_valid(self.composer.winid) then
      vim.api.nvim_set_current_win(self.composer.winid)
    end
    return self
  end
  if self.closed then
    self.closed = false
    self:_make_views()
    self:_bind()
  end
  self.layout = Layout.open({
    width = self.opts.width,
    composer_height = self.opts.composer_height,
    transcript_bufnr = self.transcript.bufnr,
    changes_bufnr = self.changes.bufnr,
    composer_bufnr = self.composer.bufnr,
  })
  self.transcript.winid = self.layout.transcript_win
  self.changes.winid = self.layout.changes_win
  self.composer.winid = self.layout.composer_win
  self:render()
  self:_render_state()
  self:_reconcile_command_approvals()
  return self
end

function UI:toggle()
  if self.layout and not self.layout.closed then
    self:close()
  else
    self:open()
  end
end

function UI:close()
  if self.closed then return end
  self.closed = true
  self.generation = self.generation + 1
  self:_unbind()
  if self.diff_view then self.diff_view:close() end
  self.diff_view = nil
  if self.layout then self.layout:close() end
  self.transcript:close()
  self.changes:close()
  self.composer:close()
  self.layout = nil
end

local M = {}

function M.new(session, opts)
  assert(session, "session is required")
  local config = require("aichatter.config").get()
  opts = vim.tbl_deep_extend("force", {}, config, opts or {})
  local self = setmetatable({
    session = session,
    opts = opts,
    layout = nil,
    closed = false,
    generation = 0,
  }, UI)
  self:_make_views()
  self:_bind()
  return self
end

return M
