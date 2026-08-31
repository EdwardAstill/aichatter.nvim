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

h.test("displays the selected model in the sidebar status line", function()
  local fixture = h.session_fixture({ files = {} })
  fixture.session.model = "gpt-5.6-sol"
  local ui = require("aichatter.ui").new(fixture.session, {})
  ui:open()

  h.matches("gpt%-5%.6%-sol", vim.wo[ui.transcript.winid].statusline)
  fixture.session.model = "gpt-5.6-terra"
  fixture.session:_emit("model", "gpt-5.6-terra")
  h.matches("gpt%-5%.6%-terra", vim.wo[ui.transcript.winid].statusline)

  ui:close()
end)

h.test("prompts once for a command approval that arrived while hidden", function()
  local fixture = h.session_fixture({
    state = "running",
    turn_id = "turn-1",
    files = {},
  })
  local prompts = {}
  local ui = require("aichatter.ui").new(fixture.session, {
    ui_select = function(items, opts, callback)
      prompts[#prompts + 1] = { items = items, opts = opts, callback = callback }
    end,
  })
  ui:open()
  ui:toggle()

  fixture.transport:server_request(51, "item/commandExecution/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "command-1",
  })
  h.eq(0, #prompts)
  h.truthy(fixture.session.pending_commands[51])

  ui:open()
  ui:open()
  h.eq(1, #prompts)
  h.eq({ "Approve once", "Decline" }, prompts[1].items)
  prompts[1].callback("Approve once")
  h.eq({ decision = "accept" }, fixture.transport.responses[51].result)
  h.eq(nil, fixture.session.pending_commands[51])
  ui:close()
end)

h.test("toggle hides and restores composer and candidate draft buffers", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "old\n",
    candidate = "new\n",
  })
  local session = {
    state = "reviewable",
    transcript = {},
    context = { files = {}, selections = {} },
    review = review,
    emit = function() end,
  }
  function session:send() end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "draft prompt" })
  ui:_open_review(review.record)
  h.invoke_mapping(ui.diff_view.bufnr, "n", "e")
  local composer = ui.composer.bufnr
  local candidate = ui.diff_view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "local candidate draft" })
  vim.bo[candidate].modified = true

  ui:toggle()

  h.truthy(vim.api.nvim_buf_is_valid(composer))
  h.truthy(vim.api.nvim_buf_is_valid(candidate))
  h.eq({ "draft prompt" }, vim.api.nvim_buf_get_lines(composer, 0, -1, false))
  h.eq({ "local candidate draft" }, vim.api.nvim_buf_get_lines(candidate, 0, -1, false))
  h.truthy(vim.bo[candidate].modified)

  ui:toggle()

  h.eq(composer, ui.composer.bufnr)
  h.eq(candidate, ui.diff_view.candidate_bufnr)
  h.eq({ "draft prompt" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  h.eq({ "local candidate draft" },
    vim.api.nvim_buf_get_lines(ui.diff_view.candidate_bufnr, 0, -1, false))
  ui:close()
end)

h.test("refuses to switch review files away from a modified candidate draft", function()
  local records = {
    {
      path = "first.lua",
      base = "old\n",
      candidate = "new\n",
    },
    {
      path = "second.lua",
      base = "before\n",
      candidate = "after\n",
    },
  }
  for _, record in ipairs(records) do
    record.hunks = require("aichatter.diff").hunks(record.base, record.candidate)
  end
  local review = { records = records }
  function review:files() return self.records end
  function review:edit_candidate(_, _, callback) callback() end
  local notified
  local session = {
    state = "reviewable",
    transcript = {},
    context = { files = {}, selections = {} },
    review = review,
    emit = function() end,
  }
  function session:send() end
  local ui = require("aichatter.ui").new(session, {
    notify = function(message) notified = message end,
  })
  ui:open()
  ui:_open_review(records[1])
  h.invoke_mapping(ui.diff_view.bufnr, "n", "e")
  local candidate = ui.diff_view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "do not discard" })
  vim.bo[candidate].modified = true

  ui:_open_review(records[2])

  h.eq("first.lua", ui.diff_view.path)
  h.eq(candidate, ui.diff_view.candidate_bufnr)
  h.eq({ "do not discard" }, vim.api.nvim_buf_get_lines(candidate, 0, -1, false))
  h.truthy(vim.bo[candidate].modified)
  h.matches("modified candidate", notified or "")
  ui:close()
end)

h.test("review queue actions go through the session coordinator", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "old\n",
    candidate = "new\n",
  })
  local calls = {}
  local session = {
    state = "reviewable",
    transcript = {},
    context = { files = {}, selections = {} },
    review = review,
    emit = function() end,
  }
  function session:send() end
  function session:review_action(method, path, callback)
    calls[#calls + 1] = { method = method, path = path }
    callback()
    return true
  end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()

  ui:_review_action("accept_file", review.record)

  h.eq({ { method = "accept_file", path = "main.lua" } }, calls)
  h.eq({}, review.accepted_hunks)
  ui:close()
end)

h.test("reconciles an open diff and clean candidate after a refreshed turn", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "old\n",
    candidate = "first\n",
  })
  local session = {
    state = "reviewable",
    transcript = {},
    context = { files = {}, selections = {} },
    review = review,
    emit = function() end,
  }
  function session:send() end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  ui:_open_review(review.record)
  local view = ui.diff_view
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_win_set_buf(view.winid, view.bufnr)
  vim.api.nvim_set_current_win(view.winid)

  review.record.candidate = "second\n"
  review.record.hunks = require("aichatter.diff").hunks(
    review.record.base, review.record.candidate)
  session.emit("state", "reviewable")

  h.matches("%+second", h.buffer_text(view.bufnr))
  h.invoke_mapping(view.bufnr, "n", "e")
  h.eq({ "second" }, vim.api.nvim_buf_get_lines(candidate, 0, -1, false))
  h.falsy(vim.b[candidate].aichatter_stale)
  ui:close()
end)

h.test("preserves and marks a modified candidate after an errored queue mutation", function()
  local review = h.fake_review({
    path = "main.lua",
    base = "old\n",
    candidate = "first\n",
  })
  function review:accept_file(_, callback)
    self.record.candidate = "queue latest\n"
    self.record.status = "conflict"
    self.record.hunks = require("aichatter.diff").hunks(
      self.record.base, self.record.candidate)
    callback({ message = "accept failed after refresh" })
  end
  local session = {
    state = "reviewable",
    transcript = {},
    context = { files = {}, selections = {} },
    review = review,
    emit = function() end,
  }
  function session:send() end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  ui:_open_review(review.record)
  local view = ui.diff_view
  h.invoke_mapping(view.bufnr, "n", "e")
  local candidate = view.candidate_bufnr
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, { "local draft" })
  vim.bo[candidate].modified = true
  vim.api.nvim_win_set_buf(view.winid, view.bufnr)

  ui:_review_action("accept_file", review.record)

  h.eq({ "local draft" }, vim.api.nvim_buf_get_lines(candidate, 0, -1, false))
  h.truthy(vim.bo[candidate].modified)
  h.truthy(vim.b[candidate].aichatter_stale)
  local warning = vim.inspect(vim.api.nvim_buf_get_extmarks(
    candidate, view.candidate_namespace, 0, -1, { details = true }))
  h.matches(":write replaces", warning)
  h.matches("%+queue latest", h.buffer_text(view.bufnr))
  h.matches("%[conflict%]", h.buffer_text(ui.changes.bufnr))
  h.matches("accept failed after refresh", h.buffer_text(ui.transcript.bufnr))
  ui:close()
end)

h.test("rejects tiny screens without leaking windows buffers or focus", function()
  dimensions(20, 7, function()
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
