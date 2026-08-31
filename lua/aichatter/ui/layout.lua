local Layout = {}
Layout.__index = Layout

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function sidebar_width(fraction)
  local columns = vim.o.columns
  if columns < 80 then return math.max(1, math.floor(columns / 2)) end
  return math.max(40, math.min(math.floor(columns * fraction), columns - 40))
end

local function composer_height(fraction)
  return math.max(3, math.floor(vim.o.lines * fraction))
end

local function scratch_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  return bufnr
end

local function configure_window(winid)
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].wrap = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
end

local function split_with_buffer(command, bufnr, split)
  split(command)
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  configure_window(winid)
  return winid
end

function Layout:_set_width()
  local width = sidebar_width(self.width)
  for _, winid in ipairs({ self.transcript_win, self.changes_win, self.composer_win }) do
    if valid_window(winid) then vim.api.nvim_win_set_width(winid, width) end
  end
end

function Layout:_set_heights()
  if valid_window(self.changes_win) then
    local cap = math.max(1, math.floor(vim.o.lines * 0.25))
    vim.api.nvim_win_set_height(self.changes_win, math.max(1, math.min(self.change_lines, cap)))
  end
  if valid_window(self.composer_win) then
    vim.api.nvim_win_set_height(self.composer_win, composer_height(self.composer_height))
  end
end

function Layout:resize()
  if self.closed then return end
  self:_set_width()
  self:_set_heights()
end

function Layout:set_changes_height(line_count)
  self.change_lines = math.max(1, line_count or 1)
  if not valid_window(self.changes_win) then self:show_changes(line_count) end
  self:_set_heights()
end

function Layout:hide_changes()
  if not valid_window(self.changes_win) then
    self.changes_win = nil
    return
  end
  vim.api.nvim_win_hide(self.changes_win)
  self.changes_win = nil
end

function Layout:show_changes(line_count)
  if self.closed or valid_window(self.changes_win) then
    if line_count then self:set_changes_height(line_count) end
    return self.changes_win
  end
  if not valid_window(self.transcript_win) then return nil end
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(self.transcript_win)
  self.changes_win = split_with_buffer("belowright split", self.changes_bufnr, self.split)
  vim.wo[self.changes_win].winfixheight = true
  self.change_lines = math.max(1, line_count or self.change_lines)
  self:resize()
  if valid_window(current) then vim.api.nvim_set_current_win(current) end
  return self.changes_win
end

function Layout:close()
  if self.closed then return end
  self.closed = true
  if self.augroup then pcall(vim.api.nvim_del_augroup_by_id, self.augroup) end
  for _, winid in ipairs({ self.composer_win, self.changes_win, self.transcript_win }) do
    if valid_window(winid) then pcall(vim.api.nvim_win_close, winid, true) end
  end
  if valid_window(self.main_win) then vim.api.nvim_set_current_win(self.main_win) end
  for _, bufnr in ipairs(self.owned_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local M = {}

function M.open(opts)
  opts = opts or {}
  if vim.o.columns < 20 or vim.o.lines < 8 then
    error("aichatter sidebar requires at least 20 columns and 8 lines", 0)
  end
  local main_win = vim.api.nvim_get_current_win()
  local initial_windows = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    initial_windows[winid] = true
  end
  local owned_buffers = {}
  local function buffer(value)
    if value then return value end
    local bufnr = scratch_buffer()
    owned_buffers[#owned_buffers + 1] = bufnr
    return bufnr
  end

  local self = setmetatable({
    main_win = main_win,
    width = opts.width or 0.35,
    composer_height = opts.composer_height or 0.20,
    transcript_bufnr = buffer(opts.transcript_bufnr),
    changes_bufnr = buffer(opts.changes_bufnr),
    composer_bufnr = buffer(opts.composer_bufnr),
    change_lines = 1,
    owned_buffers = owned_buffers,
    split = opts.split or vim.cmd,
    closed = false,
  }, Layout)

  local ok, err = xpcall(function()
    self.transcript_win = split_with_buffer(
      "rightbelow vsplit", self.transcript_bufnr, self.split)
    self.changes_win = split_with_buffer(
      "belowright split", self.changes_bufnr, self.split)
    self.composer_win = split_with_buffer(
      "belowright split", self.composer_bufnr, self.split)
    vim.wo[self.changes_win].winfixheight = true
    vim.wo[self.composer_win].winfixheight = true
    self:resize()

    self.augroup = vim.api.nvim_create_augroup("aichatter-layout-" .. self.transcript_bufnr,
      { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
      group = self.augroup,
      callback = function() self:resize() end,
    })
  end, debug.traceback)
  if not ok then
    self.closed = true
    if self.augroup then pcall(vim.api.nvim_del_augroup_by_id, self.augroup) end
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if not initial_windows[winid] and valid_window(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    if valid_window(main_win) then vim.api.nvim_set_current_win(main_win) end
    for _, bufnr in ipairs(owned_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    error(err, 0)
  end
  return self
end

return M
