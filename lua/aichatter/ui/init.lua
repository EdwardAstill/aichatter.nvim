local Layout = require("aichatter.ui.layout")
local Transcript = require("aichatter.ui.transcript")
local Composer = require("aichatter.ui.composer")
local Changes = require("aichatter.ui.changes")

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

function UI:_files()
  if not self.session.review or type(self.session.review.files) ~= "function" then return {} end
  return self.session.review:files() or {}
end

function UI:_report_error(err)
  if not err then return end
  local entries = vim.list_slice(self.session.transcript or {})
  entries[#entries + 1] = { type = "error", error = err }
  self.transcript:render(entries)
end

function UI:_review_action(method, file)
  local review = self.session.review
  if not review or type(review[method]) ~= "function" then return end
  review[method](review, file.path, function(err)
    self:_report_error(err)
    if not err then self:render() end
  end)
end

function UI:_make_views()
  local mappings = self.opts.mappings or {}
  self.transcript = Transcript.new({ schedule = self.opts.schedule })
  self.composer = Composer.new({
    mappings = mappings,
    on_submit = self.opts.on_submit or function(text)
      local state = self.session.state
      if state ~= "idle" and state ~= "reviewable" then return false end
      local synchronous, rejected = true, false
      self.session:send(text, function(err)
        if synchronous and err then rejected = true end
        self:_report_error(err)
      end)
      synchronous = false
      return not rejected
    end,
  })
  self.changes = Changes.new({
    mappings = mappings,
    on_open = self.opts.on_open,
    on_accept = self.opts.on_accept or function(file)
      self:_review_action("accept_file", file)
    end,
    on_reject = self.opts.on_reject or function(file)
      self:_review_action("reject_file", file)
    end,
  })
end

function UI:_event(name)
  if name == "item/agentMessage/delta" then
    self.transcript:schedule_render(self.session.transcript or {})
  else
    self.transcript:render(self.session.transcript or {})
  end
  self.composer:render(self.session.context or {})
  if name == "state" or name == "turn/completed" then self:render_changes() end
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

function UI:render()
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
  self:_unbind()
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
  }, UI)
  self:_make_views()
  self:_bind()
  return self
end

return M
