local h = require("tests.helpers")

local function dimensions(columns, lines, fn)
  local old_columns, old_lines = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = columns, lines
  local ok, err = xpcall(fn, debug.traceback)
  vim.o.columns, vim.o.lines = old_columns, old_lines
  assert(ok, err)
end

h.test("creates transcript, changes, and 20 percent composer windows", function()
  dimensions(160, 50, function()
    local layout = require("aichatter.ui.layout").open({
      width = 0.35,
      composer_height = 0.20,
    })
    h.eq(56, vim.api.nvim_win_get_width(layout.transcript_win))
    h.eq(vim.api.nvim_win_get_width(layout.transcript_win),
      vim.api.nvim_win_get_width(layout.composer_win))
    h.eq(10, vim.api.nvim_win_get_height(layout.composer_win))
    h.truthy(vim.api.nvim_win_is_valid(layout.changes_win))
    layout:close()
  end)
end)

h.test("clamps wide layouts and splits narrow screens evenly", function()
  dimensions(100, 40, function()
    local minimum = require("aichatter.ui.layout").open({ width = 0.20 })
    h.eq(40, vim.api.nvim_win_get_width(minimum.transcript_win))
    minimum:close()

    local maximum = require("aichatter.ui.layout").open({ width = 0.90 })
    h.eq(60, vim.api.nvim_win_get_width(maximum.transcript_win))
    maximum:close()
  end)
  dimensions(70, 40, function()
    local narrow = require("aichatter.ui.layout").open({ width = 0.90 })
    h.eq(35, vim.api.nvim_win_get_width(narrow.transcript_win))
    narrow:close()
  end)
end)

h.test("resizes sidebar and caps the changed-file queue", function()
  dimensions(120, 60, function()
    local layout = require("aichatter.ui.layout").open({
      width = 0.35,
      composer_height = 0.20,
    })
    h.eq(42, vim.api.nvim_win_get_width(layout.transcript_win))
    h.eq(12, vim.api.nvim_win_get_height(layout.composer_win))
    layout:set_changes_height(99)
    h.truthy(vim.api.nvim_win_get_height(layout.changes_win) <= 15)

    vim.o.columns, vim.o.lines = 140, 50
    layout:resize()
    h.eq(49, vim.api.nvim_win_get_width(layout.transcript_win))
    h.eq(10, vim.api.nvim_win_get_height(layout.composer_win))
    layout:close()
  end)
end)

h.test("restores the prior main window and closes idempotently", function()
  local main_win = vim.api.nvim_get_current_win()
  local layout = require("aichatter.ui.layout").open({})
  h.truthy(main_win ~= layout.transcript_win)
  layout:close()
  layout:close()
  h.eq(main_win, vim.api.nvim_get_current_win())
end)

h.test("composed UI hides an empty queue and removes event handlers", function()
  local listeners = {}
  local session = {
    state = "idle",
    transcript = {},
    context = { files = {}, selections = {} },
    review = { files = function() return {} end },
  }
  function session:on(name, callback) listeners[name] = callback end
  function session:off(name, callback)
    if listeners[name] == callback then listeners[name] = nil end
  end
  function session:send() end

  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  h.falsy(ui.layout.changes_win
    and vim.api.nvim_win_is_valid(ui.layout.changes_win))
  h.truthy(next(listeners) ~= nil)

  ui:close()
  ui:close()
  h.eq(nil, next(listeners))
  h.falsy(ui.layout)
end)

h.test("rejects tiny screens without leaking windows buffers or focus", function()
  dimensions(20, 5, function()
    local main_win = vim.api.nvim_get_current_win()
    local windows = #vim.api.nvim_tabpage_list_wins(0)
    local buffers = #vim.api.nvim_list_bufs()
    h.raises("sidebar requires", function()
      require("aichatter.ui.layout").open({})
    end)
    h.eq(windows, #vim.api.nvim_tabpage_list_wins(0))
    h.eq(buffers, #vim.api.nvim_list_bufs())
    h.eq(main_win, vim.api.nvim_get_current_win())
  end)
end)

h.test("rolls back a partially opened layout when a later split fails", function()
  local main_win = vim.api.nvim_get_current_win()
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  local buffers = #vim.api.nvim_list_bufs()
  local calls = 0
  h.raises("injected split failure", function()
    require("aichatter.ui.layout").open({
      split = function(command)
        calls = calls + 1
        vim.cmd(command)
        if calls == 2 then error("injected split failure") end
      end,
    })
  end)
  h.eq(windows, #vim.api.nvim_tabpage_list_wins(0))
  h.eq(buffers, #vim.api.nvim_list_bufs())
  h.eq(main_win, vim.api.nvim_get_current_win())
end)
