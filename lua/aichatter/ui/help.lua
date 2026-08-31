local M = {}
local active

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

function M.close()
  if not active then return end
  local current = active
  active = nil
  if valid_window(current.winid) then
    pcall(vim.api.nvim_win_close, current.winid, true)
  end
  if vim.api.nvim_buf_is_valid(current.bufnr) then
    pcall(vim.api.nvim_buf_delete, current.bufnr, { force = true })
  end
end

function M.open(title, lines)
  M.close()
  lines = lines or {}
  local width = vim.fn.strdisplaywidth(title or "AI Chatter Help")
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(24, math.min(width + 4, math.max(1, vim.o.columns - 4)))
  local height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 4)))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "aichatter-help"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "single",
    title = " " .. (title or "AI Chatter Help") .. " ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[winid].statuscolumn = ""
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  active = { bufnr = bufnr, winid = winid }
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, M.close, {
      buffer = bufnr,
      silent = true,
      desc = "Close AI Chatter help",
    })
  end
  return active
end

function M.map(bufnr, title, lines)
  vim.keymap.set("n", "?", function() M.open(title, lines) end, {
    buffer = bufnr,
    silent = true,
    desc = "Show AI Chatter help",
  })
end

return M
