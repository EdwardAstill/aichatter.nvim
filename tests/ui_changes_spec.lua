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
  h.truthy(#text <= 48)
  h.matches("main.lua", text)
  h.matches("Open", text)
  h.truthy(view:activate_at(1, view.actions[1].open.start))
  h.eq(path, opened)
  view:close()
end)
