local h = require("tests.helpers")

local function marks(view)
  return vim.api.nvim_buf_get_extmarks(
    view.bufnr, view.namespace, 0, -1, { details = true })
end

h.test("renders unified context with green additions and red deletions", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "before\nold\nafter\n",
    candidate = "before\nnew\nafter\n",
  })
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  local text = h.buffer_text(view.bufnr)
  h.matches("@@ %-2,1 %+2,1 @@", text)
  h.matches(" before", text)
  h.matches("%-old", text)
  h.matches("%+new", text)
  h.truthy(h.has_highlight(marks(view), "AIChatterDiffDelete"))
  h.truthy(h.has_highlight(marks(view), "AIChatterDiffAdd"))
  h.falsy(vim.bo[view.bufnr].modifiable)
  view:close()
end)

h.test("maps each rendered line to a stable current hunk", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "one\nkeep\nthree\n",
    candidate = "ONE\nkeep\nTHREE\n",
  })
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  h.invoke_mapping(view.bufnr, "n", "a")
  h.invoke_mapping(view.bufnr, "n", "]c")
  h.invoke_mapping(view.bufnr, "n", "r")
  h.invoke_mapping(view.bufnr, "n", "[c")
  h.invoke_mapping(view.bufnr, "n", "a")
  h.eq({ 1, 1 }, review.accepted_hunks)
  h.eq({ 2 }, review.rejected_hunks)
  view:close()
end)

h.test("writes a complete candidate through a non-live acwrite name", function()
  local review = h.fake_review({
    path = "lua/main.lua",
    base = "old\n",
    candidate = "new\n",
  })
  local view = require("aichatter.ui.diff").open(review, "lua/main.lua")
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  h.truthy(candidate and vim.api.nvim_buf_is_valid(candidate))
  h.eq("acwrite", vim.bo[candidate].buftype)
  h.falsy(vim.api.nvim_buf_get_name(candidate) == "lua/main.lua")
  h.falsy(vim.api.nvim_buf_get_name(candidate):find("/lua/main.lua", 1, true))

  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "complete", "candidate" })
  vim.bo[candidate].endofline = true
  vim.bo[candidate].modified = true
  vim.api.nvim_set_current_buf(candidate)
  vim.cmd("write")

  h.eq({ "complete\ncandidate\n" }, review.edited_candidates)
  h.falsy(vim.bo[candidate].modified)
  h.matches("%+complete", h.buffer_text(view.bufnr))
  view:close()
end)

h.test("keeps a failed candidate write modified and leaves the diff unchanged", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  review.edit_error = { message = "shadow write failed" }
  local notified
  local view = require("aichatter.ui.diff").open(review, "main.lua", {
    notify = function(message) notified = message end,
  })
  local before = h.buffer_text(view.bufnr)
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "broken" })
  vim.bo[candidate].modified = true
  vim.api.nvim_set_current_buf(candidate)
  vim.cmd("write")
  h.truthy(vim.bo[candidate].modified)
  h.eq(before, h.buffer_text(view.bufnr))
  h.matches("shadow write failed", notified)
  view:close()
end)

h.test("does not clear newer candidate edits after an asynchronous write", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  local written, complete
  function review:edit_candidate(path, bytes, callback)
    h.eq("main.lua", path)
    written, complete = bytes, callback
  end
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "persisted" })
  vim.bo[candidate].endofline = true
  vim.bo[candidate].modified = true
  vim.api.nvim_set_current_buf(candidate)
  vim.cmd("write")
  h.eq("persisted\n", written)

  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "newer local edit" })
  review.record.candidate = written
  review.record.hunks = require("aichatter.diff").hunks(review.record.base, written)
  complete()

  h.truthy(vim.bo[candidate].modified)
  h.eq(candidate, vim.api.nvim_get_current_buf())
  h.matches("%+persisted", h.buffer_text(view.bufnr))
  view:close()
end)

h.test("registers the approved commands exactly once", function()
  vim.g.loaded_aichatter = nil
  dofile("plugin/aichatter.lua")
  dofile("plugin/aichatter.lua")
  for _, name in ipairs({
    "AIChat", "AIChatLogin", "AIChatAddFile",
    "AIChatAddSelection", "AIChatCancel", "AIChatClose",
  }) do
    h.eq(2, vim.fn.exists(":" .. name))
  end
end)
