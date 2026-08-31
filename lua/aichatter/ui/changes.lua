local Changes = {}
Changes.__index = Changes

local function counts(file)
  if file.additions ~= nil or file.deletions ~= nil then
    return file.additions or 0, file.deletions or 0
  end
  local additions, deletions = 0, 0
  for _, hunk in ipairs(file.hunks or {}) do
    additions = additions + (hunk.candidate_count or #(hunk.candidate_lines or {}))
    deletions = deletions + (hunk.base_count or #(hunk.base_lines or {}))
  end
  return additions, deletions
end

local function visible_path(path, available)
  if #path <= available then return path end
  if available <= 3 then return path:sub(-available) end
  return "..." .. path:sub(-(available - 3))
end

function Changes:_width()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    return vim.api.nvim_win_get_width(self.winid)
  end
  return self.width
end

function Changes:_row(file)
  local additions, deletions = counts(file)
  local suffix = string.format("  +%d -%d  [%s]  Open  ✓  ✕",
    additions, deletions, file.status or "pending")
  local path = visible_path(file.path or "", math.max(1, self:_width() - #suffix))
  local row = path .. suffix
  local spans = {}
  for _, action in ipairs({
    { name = "open", label = "Open" },
    { name = "accept", label = "✓" },
    { name = "reject", label = "✕" },
  }) do
    local first = assert(row:find(action.label, 1, true)) - 1
    spans[action.name] = { start = first, finish = first + #action.label }
  end
  return row, spans
end

function Changes:render(files)
  self.files = files or {}
  self.actions = {}
  local rows = {}
  for index, file in ipairs(self.files) do
    rows[index], self.actions[index] = self:_row(file)
  end
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, rows)
  vim.bo[self.bufnr].modifiable = false
end

function Changes:_invoke(action, row)
  local file = self.files[row]
  local callback = self.callbacks[action]
  if not file or not callback then return false end
  callback(file)
  return true
end

function Changes:activate_at(row, byte_column)
  local actions = self.actions[row]
  if not actions then return false end
  for _, action in ipairs({ "open", "accept", "reject" }) do
    local span = actions[action]
    if byte_column >= span.start and byte_column < span.finish then
      return self:_invoke(action, row)
    end
  end
  return false
end

function Changes:_cursor_action(action)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return self:_invoke(action, row)
end

function Changes:_mouse_action()
  local mouse = vim.fn.getmousepos()
  if not mouse.winid or mouse.winid == 0 or not vim.api.nvim_win_is_valid(mouse.winid) then
    return false
  end
  if vim.api.nvim_win_get_buf(mouse.winid) ~= self.bufnr then return false end
  return self:activate_at(mouse.line, mouse.column - 1)
end

function Changes:close()
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
  local config = require("aichatter.config").get()
  local mappings = vim.tbl_extend("force", {
    open = config.mappings.open,
    accept = config.mappings.accept,
    reject = config.mappings.reject,
  }, opts.mappings or {})
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "aichatter-changes"
  local self = setmetatable({
    bufnr = bufnr,
    winid = nil,
    width = opts.width or 80,
    files = {},
    actions = {},
    callbacks = {
      open = opts.on_open,
      accept = opts.on_accept or opts.on_accept_all,
      reject = opts.on_reject or opts.on_reject_all,
    },
    closed = false,
  }, Changes)
  vim.keymap.set("n", mappings.open, function() self:_cursor_action("open") end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.accept, function() self:_cursor_action("accept") end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.reject, function() self:_cursor_action("reject") end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function() self:_mouse_action() end,
    { buffer = bufnr, silent = true })
  return self
end

return M
