local h = require("tests.helpers")

local function one_file(path)
  return {
    path = path or "lua/main.lua",
    additions = 8,
    deletions = 3,
    status = "pending",
  }
end

h.test("renders file counts, status, and stable action spans", function()
  local view = require("aichatter.ui.changes").new({})
  view:render({ one_file() })
  local text = h.buffer_text(view.bufnr)
  h.matches("lua/main.lua", text)
  h.matches("+8", text)
  h.matches("%-3", text)
  h.matches("pending", text)
  h.matches("Open", text)
  h.matches("✓", text)
  h.matches("✕", text)
  h.truthy(view.actions[1].open.finish <= view.actions[1].accept.start)
  h.truthy(view.actions[1].accept.finish <= view.actions[1].reject.start)
  view:close()
end)

h.test("keyboard and mouse dispatch through the same row actions", function()
  local calls = {}
  local view = require("aichatter.ui.changes").new({
    on_open = function(file) calls[#calls + 1] = "open:" .. file.path end,
    on_accept = function(file) calls[#calls + 1] = "accept:" .. file.path end,
    on_reject = function(file) calls[#calls + 1] = "reject:" .. file.path end,
  })
  view:render({ one_file() })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  h.invoke_mapping(view.bufnr, "n", "o")
  h.invoke_mapping(view.bufnr, "n", "a")
  h.invoke_mapping(view.bufnr, "n", "r")
  h.eq({ "open:lua/main.lua", "accept:lua/main.lua", "reject:lua/main.lua" }, calls)

  calls = {}
  h.truthy(view:activate_at(1, view.actions[1].open.start))
  h.truthy(view:activate_at(1, view.actions[1].accept.start))
  h.truthy(view:activate_at(1, view.actions[1].reject.finish - 1))
  h.eq({ "open:lua/main.lua", "accept:lua/main.lua", "reject:lua/main.lua" }, calls)
  view:close()
end)

h.test("Enter opens the selected changed file", function()
  local opened
  local view = require("aichatter.ui.changes").new({
    on_open = function(file) opened = file.path end,
  })
  view:render({ one_file() })

  h.invoke_mapping(view.bufnr, "n", "<CR>")

  h.eq("lua/main.lua", opened)
  view:close()
end)

h.test("question mark opens changed-file help and q closes it", function()
  local view = require("aichatter.ui.changes").new({})
  vim.api.nvim_set_current_buf(view.bufnr)
  h.truthy(vim.fn.maparg("?", "n", false, true).callback ~= nil)

  h.invoke_mapping(view.bufnr, "n", "?")

  local help_buf = vim.api.nvim_get_current_buf()
  local help_win = vim.api.nvim_get_current_win()
  h.eq("aichatter-help", vim.bo[help_buf].filetype)
  h.eq("editor", vim.api.nvim_win_get_config(help_win).relative)
  h.matches("Accept file", h.buffer_text(help_buf))
  h.matches("Reject file", h.buffer_text(help_buf))
  h.invoke_mapping(help_buf, "n", "q")
  h.falsy(vim.api.nvim_win_is_valid(help_win))
  view:close()
end)

h.test("maps queue defaults through documented plug mappings", function()
  local view = require("aichatter.ui.changes").new({})
  vim.api.nvim_set_current_buf(view.bufnr)

  h.eq("<Plug>(AIChatterChangesOpen)", vim.fn.maparg("o", "n", false, true).rhs)
  h.eq("<Plug>(AIChatterChangesAccept)", vim.fn.maparg("a", "n", false, true).rhs)
  h.eq("<Plug>(AIChatterChangesReject)", vim.fn.maparg("r", "n", false, true).rhs)
  h.eq("<Plug>(AIChatterChangesOpen)", vim.fn.maparg("<CR>", "n", false, true).rhs)
  h.truthy(vim.fn.maparg("<Plug>(AIChatterChangesOpen)", "n", false, true).callback ~= nil)
  h.truthy(vim.fn.maparg("<Plug>(AIChatterChangesAccept)", "n", false, true).callback ~= nil)
  h.truthy(vim.fn.maparg("<Plug>(AIChatterChangesReject)", "n", false, true).callback ~= nil)
  view:close()
end)

h.test("queue action callback errors are returned without throwing", function()
  local view = require("aichatter.ui.changes").new({
    on_accept = function() error("queued callback exploded") end,
  })
  view:render({ one_file() })

  local ok, err = view:activate_at(1, view.actions[1].accept.start)

  h.falsy(ok)
  h.matches("queued callback exploded", err.message)
  view:close()
end)

h.test("mouse clicks invoke only exact known action spans", function()
  local calls = 0
  local view = require("aichatter.ui.changes").new({
    on_open = function() calls = calls + 1 end,
  })
  view:render({ one_file() })
  local span = view.actions[1].open
  h.falsy(view:activate_at(1, span.start - 1))
  h.truthy(view:activate_at(1, span.start))
  h.truthy(view:activate_at(1, span.finish - 1))
  h.falsy(view:activate_at(1, span.finish))
  h.falsy(view:activate_at(2, span.start))
  h.eq(2, calls)
  view:close()
end)

h.test("renders an empty queue without phantom rows", function()
  local view = require("aichatter.ui.changes").new({})
  view:render({})
  h.eq("", h.buffer_text(view.bufnr))
  h.eq({}, view.actions)
  view:close()
end)

h.test("keeps action spans reachable when paths are long", function()
  local path = string.rep("deep/", 30) .. "main.lua"
  local opened
  local view = require("aichatter.ui.changes").new({
    width = 48,
    on_open = function(file) opened = file.path end,
  })
  view:render({ one_file(path) })
  local text = h.buffer_text(view.bufnr)
  h.truthy(vim.fn.strdisplaywidth(text) <= 48)
  h.matches("main.lua", text)
  h.matches("Open", text)
  h.truthy(view:activate_at(1, view.actions[1].open.start))
  h.eq(path, opened)
  view:close()
end)

h.test("action spans ignore matching labels in path and status text", function()
  local calls = {}
  local view = require("aichatter.ui.changes").new({
    on_open = function() calls[#calls + 1] = "open" end,
    on_accept = function() calls[#calls + 1] = "accept" end,
    on_reject = function() calls[#calls + 1] = "reject" end,
  })
  view:render({ {
    path = "Open/✓/✕.lua",
    additions = 1,
    deletions = 0,
    status = "Open ✓ ✕",
  } })
  local row = h.buffer_text(view.bufnr)
  local first_open = assert(row:find("Open", 1, true)) - 1
  local first_accept = assert(row:find("✓", 1, true)) - 1
  local first_reject = assert(row:find("✕", 1, true)) - 1
  h.falsy(view:activate_at(1, first_open))
  h.falsy(view:activate_at(1, first_accept))
  h.falsy(view:activate_at(1, first_reject))
  h.truthy(view:activate_at(1, view.actions[1].open.start))
  h.truthy(view:activate_at(1, view.actions[1].accept.start))
  h.truthy(view:activate_at(1, view.actions[1].reject.start))
  h.eq({ "open", "accept", "reject" }, calls)
  view:close()
end)

h.test("truncates multibyte paths by display cells without invalid UTF-8", function()
  local path = string.rep("目录/", 16) .. "界面.lua"
  local view = require("aichatter.ui.changes").new({ width = 44 })
  view:render({ one_file(path) })
  local row = h.buffer_text(view.bufnr)
  h.truthy(pcall(vim.str_utfindex, row))
  h.truthy(vim.fn.strdisplaywidth(row) <= 44)
  h.matches("界面.lua", row)
  h.matches("Open", row)
  view:close()
end)
