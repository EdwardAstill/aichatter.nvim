local diff = require("aichatter.diff")

local View = {}
View.__index = View

local function error_message(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

local function record_for(review, relative)
  for _, record in ipairs(review:files() or {}) do
    if record.path == relative then return record end
  end
end

local function range(start, count)
  return string.format("%d,%d", count == 0 and start or start + 1, count)
end

local function buffer_bytes(bufnr)
  local bytes = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if vim.bo[bufnr].endofline then bytes = bytes .. "\n" end
  return bytes
end

local function actionable(hunk)
  return hunk.status ~= "accepted" and hunk.status ~= "rejected"
end

function View:_notify(err)
  self.notify(error_message(err), vim.log.levels.ERROR, { title = "aichatter.nvim" })
end

function View:_append(lines, value, hunk)
  lines[#lines + 1] = value
  if hunk then self.line_to_hunk[#lines] = hunk end
end

function View:_render_hunk(lines, record, hunk)
  self:_append(lines, string.format("@@ -%s +%s @@ [%s]",
    range(hunk.base_start, hunk.base_count),
    range(hunk.candidate_start, hunk.candidate_count),
    hunk.status or "pending"), hunk)
  self.hunk_lines[hunk.id] = #lines

  local base = diff.lines(record.base or "").lines
  local before = math.max(0, hunk.base_start - self.context_lines)
  for index = before + 1, hunk.base_start do
    self:_append(lines, " " .. (base[index] or ""), hunk)
  end
  for _, value in ipairs(hunk.base_lines or {}) do
    self:_append(lines, "-" .. value, hunk)
    self.highlights[#self.highlights + 1] = {
      row = #lines - 1,
      group = "AIChatterDiffDelete",
    }
  end
  for _, value in ipairs(hunk.candidate_lines or {}) do
    self:_append(lines, "+" .. value, hunk)
    self.highlights[#self.highlights + 1] = {
      row = #lines - 1,
      group = "AIChatterDiffAdd",
    }
  end
  local after = hunk.base_start + hunk.base_count
  for index = after + 1, math.min(#base, after + self.context_lines) do
    self:_append(lines, " " .. (base[index] or ""), hunk)
  end
end

function View:render(preferred_hunk)
  if self.closed or not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  local record = record_for(self.review, self.path)
  self.record = record
  self.line_to_hunk = {}
  self.hunk_lines = {}
  self.highlights = {}
  self.pending_hunks = {}
  local lines = { "--- a/" .. self.path, "+++ b/" .. self.path }

  if not record then
    lines[#lines + 1] = "(proposal resolved)"
  elseif record.binary or record.file_level then
    lines[#lines + 1] = "(whole-file review required)"
  else
    for _, hunk in ipairs(record.hunks or {}) do
      self:_render_hunk(lines, record, hunk)
      if actionable(hunk) then
        self.pending_hunks[#self.pending_hunks + 1] = hunk
      end
    end
    if #(record.hunks or {}) == 0 then lines[#lines + 1] = "(no pending hunks)" end
  end

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
  for _, highlight in ipairs(self.highlights) do
    local line = lines[highlight.row + 1] or ""
    vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, highlight.row, 0, {
      end_col = #line,
      hl_group = highlight.group,
      hl_eol = true,
    })
  end
  vim.bo[self.bufnr].modifiable = false

  local target = preferred_hunk and self.hunk_lines[preferred_hunk]
  if not target and self.pending_hunks[1] then
    target = self.hunk_lines[self.pending_hunks[1].id]
  end
  if target and self.winid and vim.api.nvim_win_is_valid(self.winid)
      and vim.api.nvim_win_get_buf(self.winid) == self.bufnr then
    vim.api.nvim_win_set_cursor(self.winid, { target, 0 })
  end
end

function View:_mark_candidate_stale(bufnr)
  vim.b[bufnr].aichatter_stale = true
  vim.api.nvim_buf_clear_namespace(bufnr, self.candidate_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, self.candidate_namespace, 0, 0, {
    virt_lines = { {
      { "AI Chatter: proposal changed; local draft preserved. :write replaces the shadow candidate.",
        "WarningMsg" },
    } },
    virt_lines_above = true,
  })
end

function View:_sync_candidate()
  local bufnr = self.candidate_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local record = self.record
  if vim.bo[bufnr].modified then
    if record and not record.binary and buffer_bytes(bufnr) == (record.candidate or "") then
      vim.b[bufnr].aichatter_stale = nil
      vim.api.nvim_buf_clear_namespace(bufnr, self.candidate_namespace, 0, -1)
    else
      self:_mark_candidate_stale(bufnr)
    end
    return
  end
  if not record or record.binary then
    self:_mark_candidate_stale(bufnr)
    return
  end
  local parsed = diff.lines(record.candidate or "")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, parsed.lines)
  vim.bo[bufnr].endofline = parsed.endofline
  vim.bo[bufnr].modified = false
  vim.b[bufnr].aichatter_stale = nil
  vim.api.nvim_buf_clear_namespace(bufnr, self.candidate_namespace, 0, -1)
end

function View:reconcile(preferred_hunk)
  self:render(preferred_hunk)
  self:_sync_candidate()
end

function View:_current_hunk()
  local winid = self.winid
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    winid = vim.api.nvim_get_current_win()
  end
  local line = vim.api.nvim_win_get_cursor(winid)[1]
  local hunk = self.line_to_hunk[line]
  if hunk and actionable(hunk) then return hunk end
  return self.pending_hunks[1]
end

function View:_move(direction)
  if #self.pending_hunks == 0 then return end
  local current = self:_current_hunk()
  local index = 1
  for candidate, hunk in ipairs(self.pending_hunks) do
    if current and hunk.id == current.id then index = candidate; break end
  end
  index = math.max(1, math.min(#self.pending_hunks, index + direction))
  local line = self.hunk_lines[self.pending_hunks[index].id]
  if line and self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_current_win(self.winid)
    vim.api.nvim_win_set_cursor(self.winid, { line, 0 })
  end
end

function View:_decide(method)
  local hunk = self:_current_hunk()
  if not hunk then return end
  local id = hunk.id
  self.review[method](self.review, self.path, id, function(err)
    if self.closed then return end
    self:reconcile(id)
    self.on_change()
    if err then self:_notify(err) end
  end)
end

function View:_open_candidate()
  self:reconcile()
  if not self.record or self.record.binary then return end
  if self.candidate_bufnr and vim.api.nvim_buf_is_valid(self.candidate_bufnr) then
    vim.api.nvim_set_current_buf(self.candidate_bufnr)
    return
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  self.candidate_bufnr = bufnr
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "aichatter-candidate"
  vim.api.nvim_buf_set_name(bufnr, "aichatter://candidate/" .. bufnr)
  vim.b[bufnr].aichatter_path = self.path
  local parsed = diff.lines(self.record.candidate or "")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, parsed.lines)
  vim.bo[bufnr].endofline = parsed.endofline
  vim.bo[bufnr].modified = false
  vim.b[bufnr].aichatter_stale = nil

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      if self.closed or self.candidate_writing then return end
      self.candidate_writing = true
      local generation = self.generation
      local origin_win = self.winid
      local bytes = buffer_bytes(bufnr)
      self.review:edit_candidate(self.path, bytes, function(err)
        self.candidate_writing = false
        if self.closed or not vim.api.nvim_buf_is_valid(bufnr) then return end
        if err then self:_notify(err); return end
        local unchanged = buffer_bytes(bufnr) == bytes
        if unchanged then vim.bo[bufnr].modified = false end
        self:reconcile()
        self.on_change()
        if unchanged and generation == self.generation
            and origin_win == vim.api.nvim_get_current_win()
            and vim.api.nvim_win_is_valid(origin_win)
            and vim.api.nvim_win_get_buf(origin_win) == bufnr then
          vim.api.nvim_win_set_buf(origin_win, self.bufnr)
        end
      end)
    end,
  })
  vim.api.nvim_win_set_buf(self.winid, bufnr)
  vim.api.nvim_set_current_win(self.winid)
end

function View:close()
  if self.closed then return end
  self.closed = true
  self.generation = self.generation + 1
  for _, bufnr in ipairs({ self.candidate_bufnr, self.bufnr }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local M = {}

function M.open(review, relative, opts)
  assert(review, "review is required")
  assert(type(relative) == "string" and relative ~= "", "review path is required")
  opts = opts or {}
  local config = require("aichatter.config").get()
  local mappings = vim.tbl_extend("force", {
    accept = config.mappings.accept,
    reject = config.mappings.reject,
    edit = config.mappings.edit,
    previous_hunk = config.mappings.previous_hunk,
    next_hunk = config.mappings.next_hunk,
  }, opts.mappings or {})
  vim.api.nvim_set_hl(0, "AIChatterDiffAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "AIChatterDiffDelete", { default = true, link = "DiffDelete" })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "aichatter-diff"
  local winid = opts.winid or vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_is_valid(winid), "review window is invalid")
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_set_current_win(winid)

  local self = setmetatable({
    review = review,
    path = relative,
    bufnr = bufnr,
    winid = winid,
    namespace = vim.api.nvim_create_namespace("aichatter-diff-" .. bufnr),
    candidate_namespace = vim.api.nvim_create_namespace("aichatter-candidate-" .. bufnr),
    context_lines = opts.context_lines or 3,
    notify = opts.notify or vim.notify,
    on_change = opts.on_change or function() end,
    generation = 1,
    closed = false,
  }, View)
  vim.keymap.set("n", mappings.previous_hunk, function() self:_move(-1) end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.next_hunk, function() self:_move(1) end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.accept, function() self:_decide("accept_hunk") end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.reject, function() self:_decide("reject_hunk") end,
    { buffer = bufnr, silent = true })
  vim.keymap.set("n", mappings.edit, function() self:_open_candidate() end,
    { buffer = bufnr, silent = true })
  self:render()
  return self
end

return M
