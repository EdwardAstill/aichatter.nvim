local Composer = {}
Composer.__index = Composer

local function valid_buffer(self)
  return not self.closed and vim.api.nvim_buf_is_valid(self.bufnr)
end

local function buffer_text(self)
  return table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n")
end

function Composer:_finish_submission(token, accepted)
  if self.pending ~= token or token.finished then return false end
  token.finished = true
  token.accepted = accepted
  self.pending = nil
  if accepted and valid_buffer(self) and buffer_text(self) == token.text then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { "" })
  end
  return accepted
end

function Composer:submit()
  if not valid_buffer(self) or self.pending then return false end
  local text = buffer_text(self)
  if vim.trim(text) == "" then return false end
  local token = { text = text, finished = false }
  self.pending = token
  local callback_finished = false
  local function complete(accepted)
    if callback_finished then return false end
    callback_finished = true
    return self:_finish_submission(token, accepted ~= false)
  end
  local ok, result = pcall(self.on_submit, text, complete)
  if not ok then
    complete(false)
    return false
  end
  if token.finished then return token.accepted end
  if result == "pending" then return true end
  return complete(result ~= false)
end

function Composer:newline()
  if not valid_buffer(self) then return false end
  local winid = self.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) ~= self.bufnr then return false end
    winid = current
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local line = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local column = math.min(cursor[2], #line)
  while column > 0 do
    local byte = line:byte(column + 1)
    if not byte or byte < 128 or byte >= 192 then break end
    column = column - 1
  end
  vim.api.nvim_buf_set_text(self.bufnr, cursor[1] - 1, column,
    cursor[1] - 1, column, { "", "" })
  vim.api.nvim_win_set_cursor(winid, { cursor[1] + 1, 0 })
  return true
end

function Composer:render(context)
  if not valid_buffer(self) then return false end
  context = context or {}
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
  local chunks = {}
  for _, file in ipairs(context.files or {}) do
    chunks[#chunks + 1] = { "@" .. file .. "  ", "Comment" }
  end
  for _, selection in ipairs(context.selections or {}) do
    chunks[#chunks + 1] = {
      string.format("@%s:%d-%d  ", selection.path, selection.first, selection.last),
      "Comment",
    }
  end
  if #chunks > 0 then
    vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, 0, 0, {
      virt_lines = { chunks },
      virt_lines_above = true,
    })
  end
  return true
end

function Composer:close()
  if self.closed then return end
  self.closed = true
  self.pending = nil
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
  local mappings = vim.tbl_extend("force", {
    submit = "<CR>",
    newline = "<C-j>",
  }, opts.mappings or {})
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "aichatter-composer"
  local self = setmetatable({
    bufnr = bufnr,
    winid = nil,
    namespace = vim.api.nvim_create_namespace("aichatter-composer-" .. bufnr),
    on_submit = opts.on_submit or function() end,
    pending = nil,
    closed = false,
  }, Composer)
  vim.keymap.set("i", "<Plug>(AIChatterComposerSubmit)", function() self:submit() end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("i", "<Plug>(AIChatterComposerNewline)", function() self:newline() end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("i", mappings.submit, "<Plug>(AIChatterComposerSubmit)",
    { buffer = bufnr, silent = true, remap = true })
  vim.keymap.set("i", mappings.newline, "<Plug>(AIChatterComposerNewline)",
    { buffer = bufnr, silent = true, remap = true })
  return self
end

return M
