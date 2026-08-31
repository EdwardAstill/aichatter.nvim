local h = require("tests.helpers")

h.test("submits joined multiline text on Enter and clears accepted input", function()
  local submitted
  local composer = require("aichatter.ui.composer").new({
    on_submit = function(text) submitted = text end,
  })
  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "hello", "world" })
  h.invoke_mapping(composer.bufnr, "i", "<CR>")
  h.eq("hello\nworld", submitted)
  h.eq({ "" }, vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false))
  composer:close()
end)

h.test("inserts a literal newline on Ctrl-J without submitting", function()
  local submissions = 0
  local composer = require("aichatter.ui.composer").new({
    on_submit = function() submissions = submissions + 1 end,
  })
  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "hello" })
  vim.api.nvim_set_current_buf(composer.bufnr)
  vim.wo.virtualedit = "onemore"
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  h.invoke_mapping(composer.bufnr, "i", "<C-j>")
  h.eq(0, submissions)
  h.eq({ "hello", "" }, vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false))
  vim.wo.virtualedit = ""
  composer:close()
end)

h.test("rejects blank text and retains input when submission is rejected", function()
  local calls = 0
  local composer = require("aichatter.ui.composer").new({
    on_submit = function()
      calls = calls + 1
      return false
    end,
  })
  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "  ", "\t" })
  h.falsy(composer:submit())
  h.eq(0, calls)

  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "keep me" })
  h.falsy(composer:submit())
  h.eq(1, calls)
  h.eq({ "keep me" }, vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false))
  composer:close()
end)

h.test("renders file and selection context chips above the composer", function()
  local composer = require("aichatter.ui.composer").new({})
  composer:render({
    files = { "lua/main.lua" },
    selections = { { path = "README.md", first = 3, last = 8 } },
  })
  local marks = vim.api.nvim_buf_get_extmarks(
    composer.bufnr,
    composer.namespace,
    0,
    -1,
    { details = true }
  )
  h.eq(1, #marks)
  local details = marks[1][4]
  h.truthy(details.virt_lines_above)
  local rendered = vim.inspect(details.virt_lines)
  h.matches("@lua/main.lua", rendered)
  h.matches("README.md:3%-8", rendered)
  composer:close()
end)

h.test("uses configurable buffer-local mappings without global mappings", function()
  local composer = require("aichatter.ui.composer").new({
    mappings = { submit = "<F6>", newline = "<F7>" },
  })
  h.eq("", vim.fn.maparg("<F6>", "i"))
  local mappings = vim.api.nvim_buf_get_keymap(composer.bufnr, "i")
  local found = false
  for _, mapping in ipairs(mappings) do
    if mapping.lhs == "<F6>" then found = true end
  end
  h.truthy(found)
  composer:close()
end)

h.test("maps composer defaults through documented plug mappings", function()
  local composer = require("aichatter.ui.composer").new({})
  vim.api.nvim_set_current_buf(composer.bufnr)

  h.eq("<Plug>(AIChatterComposerSubmit)", vim.fn.maparg("<CR>", "i", false, true).rhs)
  h.eq("<Plug>(AIChatterComposerNewline)", vim.fn.maparg("<C-j>", "i", false, true).rhs)
  h.truthy(vim.fn.maparg("<Plug>(AIChatterComposerSubmit)", "i", false, true).callback ~= nil)
  h.truthy(vim.fn.maparg("<Plug>(AIChatterComposerNewline)", "i", false, true).callback ~= nil)
  composer:close()
end)

h.test("composed UI retains text rejected synchronously by the session", function()
  local session = {
    state = "idle",
    transcript = {},
    context = { files = {}, selections = {} },
    review = { files = function() return {} end },
    emit = function() end,
  }
  function session:send(_, callback)
    callback({ code = "invalid_state", message = "not ready" })
  end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "keep this" })
  h.falsy(ui.composer:submit())
  h.eq({ "keep this" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  h.matches("not ready", h.buffer_text(ui.transcript.bufnr))
  h.eq({}, session.transcript)
  ui:close()
end)

h.test("composed UI clears context chips after an accepted session submission", function()
  local session = {
    state = "idle",
    transcript = {},
    context = { files = { "lua/main.lua" }, selections = {} },
    review = { files = function() return {} end },
    emit = function() end,
  }
  function session:send(text, callback)
    self.context.files = {}
    local entry = { type = "user", text = text }
    self.transcript[#self.transcript + 1] = entry
    self.emit("user", entry)
    callback()
  end
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  h.eq(1, #vim.api.nvim_buf_get_extmarks(
    ui.composer.bufnr, ui.composer.namespace, 0, -1, {}))
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "send this" })
  h.truthy(ui.composer:submit())
  h.eq(0, #vim.api.nvim_buf_get_extmarks(
    ui.composer.bufnr, ui.composer.namespace, 0, -1, {}))
  ui:close()
end)

local function delayed_session()
  local callbacks = {}
  local session = {
    state = "idle",
    transcript = {},
    context = { files = {}, selections = {} },
    review = { files = function() return {} end },
    emit = function() end,
    sends = 0,
  }
  function session:send(_, callback)
    self.sends = self.sends + 1
    callbacks[#callbacks + 1] = callback
  end
  return session, callbacks
end

h.test("keeps pending text through delayed failure and blocks duplicate submits", function()
  local session, callbacks = delayed_session()
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "retry me" })
  h.truthy(ui.composer:submit())
  h.falsy(ui.composer:submit())
  h.eq(1, session.sends)
  h.eq({ "retry me" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  callbacks[1]({ message = "turn start failed" })
  callbacks[1](nil)
  h.eq({ "retry me" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  h.eq(1, select(2, h.buffer_text(ui.transcript.bufnr):gsub("turn start failed", "")))
  ui:close()
end)

h.test("clears pending text only after delayed submission success", function()
  local session, callbacks = delayed_session()
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "send later" })
  h.truthy(ui.composer:submit())
  h.eq({ "send later" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  callbacks[1](nil)
  callbacks[1]({ message = "late duplicate" })
  h.eq({ "" }, vim.api.nvim_buf_get_lines(ui.composer.bufnr, 0, -1, false))
  h.falsy(h.buffer_text(ui.transcript.bufnr):find("late duplicate", 1, true))
  ui:close()
end)

h.test("ignores delayed send and review callbacks after close", function()
  local session, callbacks = delayed_session()
  local review_callback
  session.review = {
    files = function() return {} end,
    accept_file = function(_, _, callback) review_callback = callback end,
  }
  local ui = require("aichatter.ui").new(session, {})
  ui:open()
  vim.api.nvim_buf_set_lines(ui.composer.bufnr, 0, -1, false, { "pending" })
  h.truthy(ui.composer:submit())
  ui:_review_action("accept_file", { path = "main.lua" })
  ui:close()
  h.truthy(pcall(callbacks[1], { message = "late send" }))
  h.truthy(pcall(review_callback, nil))
end)

h.test("composer methods tolerate an externally deleted buffer", function()
  local composer = require("aichatter.ui.composer").new({})
  vim.api.nvim_buf_delete(composer.bufnr, { force = true })
  h.truthy(pcall(function() composer:render({ files = { "main.lua" } }) end))
  h.truthy(pcall(function() composer:newline() end))
  h.truthy(pcall(function() composer:submit() end))
  h.truthy(pcall(function() composer:close() end))
end)

h.test("Ctrl-J splits at start middle end and a multibyte boundary", function()
  local composer = require("aichatter.ui.composer").new({})
  vim.api.nvim_set_current_buf(composer.bufnr)
  vim.wo.virtualedit = "onemore"
  for _, case in ipairs({
    { line = "hello", column = 0, expected = { "", "hello" } },
    { line = "hello", column = 2, expected = { "he", "llo" } },
    { line = "hello", column = 5, expected = { "hello", "" } },
    { line = "a界b", column = 4, expected = { "a界", "b" } },
  }) do
    vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { case.line })
    vim.api.nvim_win_set_cursor(0, { 1, case.column })
    h.truthy(composer:newline())
    h.eq(case.expected, vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false))
    h.eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
  end
  vim.wo.virtualedit = ""
  composer:close()
end)
