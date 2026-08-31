local Composer = {}
Composer.__index = Composer

function Composer:submit()
  if self.closed then return false end
  local text = table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n")
  if vim.trim(text) == "" then return false end
  local ok, accepted = pcall(self.on_submit, text)
  if not ok or accepted == false then return false end
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { "" })
  return true
end

function Composer:newline()
  if not self.closed then vim.api.nvim_put({ "" }, "l", true, true) end
end

function Composer:render(context)
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
end

function Composer:close()
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
    closed = false,
  }, Composer)
  vim.keymap.set("i", mappings.submit, function() self:submit() end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("i", mappings.newline, function() self:newline() end,
    { buffer = bufnr, silent = true })
  return self
end

return M
