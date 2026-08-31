local Transcript = {}
Transcript.__index = Transcript

local function lines(value)
  if value == nil or value == "" then return { "" } end
  return vim.split(tostring(value), "\n", { plain = true })
end

local function command_text(request)
  request = request or {}
  local command = request.command or request.cmd or request.commandLine
  if type(command) == "table" then return table.concat(command, " ") end
  return command and tostring(command) or "command"
end

local function render_entry(entry)
  local result = {}
  local function add(value)
    for _, line in ipairs(lines(value)) do result[#result + 1] = line end
  end
  if entry.type == "user" then
    result[#result + 1] = "User"
    add(entry.text)
  elseif entry.type == "assistant" then
    result[#result + 1] = "Assistant"
    add(entry.text)
  elseif entry.type == "activity" then
    local item = entry.item or {}
    result[#result + 1] = "Activity · " .. tostring(entry.status or "updated")
    add(item.type or item.name or "activity")
    if item.command or item.cmd or item.commandLine then add(command_text(item)) end
  elseif entry.type == "error" then
    result[#result + 1] = "Error"
    add(type(entry.error) == "table" and entry.error.message or entry.error or entry.message)
  elseif entry.type == "approval" then
    result[#result + 1] = "Approval · " .. tostring(entry.status or "pending")
    add(command_text(entry.request))
  else
    add(entry.text or entry.message or entry.type or "")
  end
  return result
end

local function rendered_lines(entries)
  local result = {}
  for index, entry in ipairs(entries or {}) do
    if index > 1 then result[#result + 1] = "" end
    vim.list_extend(result, render_entry(entry))
  end
  return result
end

local function set_buffer_lines(self, next_lines)
  local first = 1
  while first <= #self.rendered and first <= #next_lines
      and self.rendered[first] == next_lines[first] do
    first = first + 1
  end
  if first > #self.rendered and first > #next_lines then return end
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, first - 1, -1, false,
    vim.list_slice(next_lines, first))
  vim.bo[self.bufnr].modifiable = false
  self.rendered = next_lines
  self.render_count = self.render_count + 1
end

function Transcript:render(entries)
  if entries ~= nil then self.entries = entries end
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  set_buffer_lines(self, rendered_lines(self.entries))
end

function Transcript:schedule_render(entries)
  if entries ~= nil then self.entries = entries end
  if self.render_scheduled then return end
  self.render_scheduled = true
  self.schedule(function()
    self.render_scheduled = false
    if not self.closed then self:render() end
  end)
end

function Transcript:append(entry)
  self.entries[#self.entries + 1] = entry
  self:render()
end

function Transcript:assistant_delta(delta)
  local entry = self.entries[#self.entries]
  if not entry or entry.type ~= "assistant" then
    entry = { type = "assistant", text = "" }
    self.entries[#self.entries + 1] = entry
  end
  entry.text = (entry.text or "") .. (delta or "")
  self:schedule_render()
end

function Transcript:close()
  if self.closed then return end
  self.closed = true
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    pcall(vim.api.nvim_win_close, self.winid, true)
  end
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
  end
end

local M = {}

function M.new(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "aichatter-transcript"
  return setmetatable({
    bufnr = bufnr,
    winid = nil,
    entries = {},
    rendered = {},
    render_count = 0,
    render_scheduled = false,
    schedule = opts.schedule or vim.schedule,
    closed = false,
  }, Transcript)
end

return M
