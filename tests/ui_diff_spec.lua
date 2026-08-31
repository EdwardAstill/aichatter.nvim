local h = require("tests.helpers")

local function marks(view)
  return vim.api.nvim_buf_get_extmarks(
    view.bufnr, view.namespace, 0, -1, { details = true })
end

local function maparg(bufnr, mode, lhs)
  vim.api.nvim_set_current_buf(bufnr)
  return vim.fn.maparg(lhs, mode, false, true)
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

h.test("maps review defaults through documented plug mappings", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  local view = require("aichatter.ui.diff").open(review, "main.lua")

  h.eq("<Plug>(AIChatterReviewAccept)", maparg(view.bufnr, "n", "a").rhs)
  h.eq("<Plug>(AIChatterReviewReject)", maparg(view.bufnr, "n", "r").rhs)
  h.eq("<Plug>(AIChatterReviewEdit)", maparg(view.bufnr, "n", "e").rhs)
  h.truthy(maparg(view.bufnr, "n", "<Plug>(AIChatterReviewAccept)").callback ~= nil)
  h.truthy(maparg(view.bufnr, "n", "<Plug>(AIChatterReviewReject)").callback ~= nil)
  h.truthy(maparg(view.bufnr, "n", "<Plug>(AIChatterReviewEdit)").callback ~= nil)
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

h.test("rerenders an accept conflict and lets navigation reject it", function()
  local fixture = h.review_fixture(
    "one\nkeep\nthree\n", "ONE\nkeep\nTHREE\n")
  fixture.set_live("user\nkeep\nthree\n")
  local notified, changes = nil, 0
  local view = require("aichatter.ui.diff").open(
    fixture.review, fixture.relative, {
      notify = function(message) notified = message end,
      on_change = function() changes = changes + 1 end,
    })

  h.invoke_mapping(view.bufnr, "n", "a")
  h.truthy(h.wait_for(function()
    local record = fixture.review:files()[1]
    return record and record.hunks[1] and record.hunks[1].status == "conflict"
  end, 3000))
  h.matches("overlaps proposed hunk", notified or "")
  h.matches("%[conflict%]", h.buffer_text(view.bufnr))
  h.eq(1, changes)

  h.invoke_mapping(view.bufnr, "n", "]c")
  h.invoke_mapping(view.bufnr, "n", "[c")
  h.invoke_mapping(view.bufnr, "n", "r")
  h.truthy(h.wait_for(function()
    return fixture.workspace_bytes() == "one\nkeep\nTHREE\n"
  end, 3000))
  h.eq(2, changes)
  view:close()
end)

h.test("renders textual deletions with red lines and file-level actions", function()
  local review = h.fake_review({
    path = "removed.txt",
    base = "one\ntwo\n",
    candidate = "",
    candidate_exists = false,
    file_level = true,
    binary = false,
  })
  review.accepted_files = {}
  review.rejected_files = {}
  function review:accept_file(path, callback)
    self.accepted_files[#self.accepted_files + 1] = path
    callback()
  end
  function review:reject_file(path, callback)
    self.rejected_files[#self.rejected_files + 1] = path
    callback()
  end
  local view = require("aichatter.ui.diff").open(review, "removed.txt")
  local text = h.buffer_text(view.bufnr)

  h.matches("%-one", text)
  h.matches("%-two", text)
  h.truthy(h.has_highlight(marks(view), "AIChatterDiffDelete"))
  h.invoke_mapping(view.bufnr, "n", "a")
  h.invoke_mapping(view.bufnr, "n", "r")

  h.eq({ "removed.txt" }, review.accepted_files)
  h.eq({ "removed.txt" }, review.rejected_files)
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

h.test("writes a zero-byte candidate without adding a newline", function()
  local review = h.fake_review({
    path = "empty.lua",
    base = "old\n",
    candidate = "new\n",
  })
  local view = require("aichatter.ui.diff").open(review, "empty.lua")
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "" })
  vim.bo[candidate].endofline = true
  vim.bo[candidate].modified = true
  vim.api.nvim_set_current_buf(candidate)
  vim.cmd("write")

  h.eq({ "" }, review.edited_candidates)
  h.falsy(vim.bo[candidate].modified)
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

h.test("does not steal focus when a candidate write completes after navigation", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  local complete
  function review:edit_candidate(_, bytes, callback)
    self.record.candidate = bytes
    self.record.hunks = require("aichatter.diff").hunks(self.record.base, bytes)
    complete = callback
  end
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  local origin = view.winid
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "persisted" })
  vim.bo[candidate].modified = true
  vim.cmd("write")

  vim.cmd("new")
  local navigated = vim.api.nvim_get_current_win()
  complete()

  h.eq(navigated, vim.api.nvim_get_current_win())
  h.eq(candidate, vim.api.nvim_win_get_buf(origin))
  vim.api.nvim_win_close(navigated, true)
  view:close()
end)

h.test("leaves a modified replacement buffer alone after a candidate write", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  local complete
  function review:edit_candidate(_, bytes, callback)
    self.record.candidate = bytes
    self.record.hunks = require("aichatter.diff").hunks(self.record.base, bytes)
    complete = callback
  end
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  local origin = view.winid
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "persisted" })
  vim.bo[candidate].modified = true
  vim.cmd("write")

  local replacement = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(replacement, 0, -1, false, { "do not replace" })
  vim.bo[replacement].modified = true
  vim.api.nvim_win_set_buf(origin, replacement)
  h.truthy(pcall(complete))

  h.eq(origin, vim.api.nvim_get_current_win())
  h.eq(replacement, vim.api.nvim_win_get_buf(origin))
  h.truthy(vim.bo[replacement].modified)
  view:close()
  vim.api.nvim_buf_delete(replacement, { force = true })
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
