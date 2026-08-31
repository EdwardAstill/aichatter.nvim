local h = require("tests.helpers")

local aichatter = require("aichatter")
local original_cwd = assert((vim.uv or vim.loop).cwd())
local fake_server = original_cwd .. "/tests/fixtures/fake_app_server.lua"

local function fake_command(scenario)
  return {
    vim.v.progpath, "--headless", "-u", "NONE", "-l",
    fake_server, scenario,
  }
end

local function buffers(filetype)
  local found = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == filetype then
      found[#found + 1] = bufnr
    end
  end
  return found
end

local function buffer(filetype)
  local found = buffers(filetype)
  return found[#found]
end

local function window_for(bufnr)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then return winid end
  end
end

local function status_is(state)
  local bufnr = buffer("aichatter-transcript")
  local winid = bufnr and window_for(bufnr)
  return winid and vim.wo[winid].statusline:find(state, 1, true) ~= nil
end

local function composer_metadata()
  local bufnr = buffer("aichatter-composer")
  if not bufnr then return "" end
  local namespace = vim.api.nvim_get_namespaces()["aichatter-composer-" .. bufnr]
  if not namespace then return "" end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, namespace, 0, -1, { details = true })
  return #marks > 0 and vim.inspect(marks[1][4].virt_lines) or ""
end

local function session_root(temp_parent)
  local matches = vim.fn.glob(temp_parent .. "/aichatter-*", false, true)
  return #matches == 1 and matches[1] or nil
end

local function configure(root, scenario)
  vim.cmd("cd " .. vim.fn.fnameescape(root))
  aichatter.setup({ codex_cmd = fake_command(scenario) })
end

local function submit(text)
  local bufnr = assert(buffer("aichatter-composer"), "composer buffer not found")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  h.invoke_mapping(bufnr, "i", "<CR>")
end

local function close_chat()
  vim.cmd("AIChatClose")
  h.truthy(h.wait_for(function()
    return #buffers("aichatter-composer") == 0
  end, 3000))
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end

h.test("composes sidebar shadow turn hunk review and confirmed cleanup end to end", function()
  local root = h.git_project({
    ["main.lua"] = "one disk\nkeep two\nthree disk\nkeep four\nfive disk\n",
  })
  local live = h.load_buffer(root .. "/main.lua", {
    "one unsaved", "keep two", "three unsaved", "keep four", "five unsaved",
  }, true)
  vim.api.nvim_set_current_buf(live)
  local temp_parent = h.tempdir()
  local exit_marker = temp_parent .. "/fake-exited"
  local old_tmpdir = vim.env.TMPDIR
  local old_exit_marker = vim.env.AICHATTER_FAKE_EXIT_MARKER
  vim.env.TMPDIR = temp_parent
  vim.env.AICHATTER_FAKE_EXIT_MARKER = exit_marker
  configure(root, "e2e-turn")

  local initial_windows = #vim.api.nvim_tabpage_list_wins(0)
  vim.cmd("AIChat")
  h.eq(initial_windows + 2, #vim.api.nvim_tabpage_list_wins(0))
  h.eq(1, #buffers("aichatter-transcript"))
  h.eq(1, #buffers("aichatter-changes"))
  h.eq(1, #buffers("aichatter-composer"))
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))

  submit("change main.lua")
  local transcript = assert(buffer("aichatter-transcript"))
  local changes = assert(buffer("aichatter-changes"))
  h.truthy(h.wait_for(function()
    return h.buffer_text(transcript):find("streamed proposal", 1, true) ~= nil
  end, 3000))
  h.eq("", h.buffer_text(changes))
  h.eq("one disk\nkeep two\nthree disk\nkeep four\nfive disk\n",
    h.read(root .. "/main.lua"))
  h.eq("one unsaved\nkeep two\nthree unsaved\nkeep four\nfive unsaved",
    h.buffer_text(live))

  local isolated = assert(session_root(temp_parent), "session directory not found")
  h.write(isolated .. "/control/release-turn", "release\n")
  h.truthy(h.wait_for(function()
    return h.buffer_text(changes):find("main.lua", 1, true) ~= nil
      and status_is("reviewable")
  end, 5000))
  h.eq("one disk\nkeep two\nthree disk\nkeep four\nfive disk\n",
    h.read(root .. "/main.lua"))
  h.eq("one unsaved\nkeep two\nthree unsaved\nkeep four\nfive unsaved",
    h.buffer_text(live))

  vim.api.nvim_set_current_win(assert(window_for(changes)))
  h.invoke_mapping(changes, "n", "<CR>")
  local diff_buf = assert(buffer("aichatter-diff"), "diff buffer not found")
  local namespace = assert(vim.api.nvim_get_namespaces()["aichatter-diff-" .. diff_buf])
  local extmarks = vim.api.nvim_buf_get_extmarks(
    diff_buf, namespace, 0, -1, { details = true })
  h.truthy(h.has_highlight(extmarks, "AIChatterDiffDelete"))
  h.truthy(h.has_highlight(extmarks, "AIChatterDiffAdd"))
  h.invoke_mapping(diff_buf, "n", "a")
  h.truthy(h.wait_for(function()
    return h.buffer_text(live):find("one codex", 1, true) ~= nil
  end, 3000))
  h.invoke_mapping(diff_buf, "n", "]c")
  h.invoke_mapping(diff_buf, "n", "r")
  h.truthy(h.wait_for(function()
    return h.buffer_text(live) ==
      "one codex\nkeep two\nthree unsaved\nkeep four\nfive unsaved"
  end, 3000))
  h.eq("one codex\nkeep two\nthree codex\nkeep four\nfive unsaved\n",
    h.read(isolated .. "/workspace/main.lua"))
  h.eq("one disk\nkeep two\nthree disk\nkeep four\nfive disk\n",
    h.read(root .. "/main.lua"))
  h.truthy(vim.bo[live].modified)

  h.invoke_mapping(diff_buf, "n", "e")
  local candidate = assert(buffer("aichatter-candidate"), "candidate buffer not found")
  vim.api.nvim_buf_set_lines(candidate, 0, -1, false, {
    "one codex", "keep two", "three edited", "keep four", "five unsaved",
  })
  vim.bo[candidate].endofline = true
  vim.bo[candidate].modified = true
  vim.api.nvim_set_current_buf(candidate)
  vim.cmd("write")
  h.truthy(h.wait_for(function()
    return h.buffer_text(diff_buf):find("+three edited", 1, true) ~= nil
      and vim.api.nvim_get_current_buf() == diff_buf
  end, 3000))
  h.eq("one codex\nkeep two\nthree edited\nkeep four\nfive unsaved\n",
    h.read(isolated .. "/workspace/main.lua"))
  h.invoke_mapping(diff_buf, "n", "[c")
  local hunk_line = vim.api.nvim_win_get_cursor(0)[1]
  h.matches("^@@", vim.api.nvim_buf_get_lines(
    diff_buf, hunk_line - 1, hunk_line, false)[1])
  h.invoke_mapping(diff_buf, "n", "]c")
  h.eq(hunk_line, vim.api.nvim_win_get_cursor(0)[1])
  h.eq("one codex\nkeep two\nthree unsaved\nkeep four\nfive unsaved",
    h.buffer_text(live))
  h.eq("one disk\nkeep two\nthree disk\nkeep four\nfive disk\n",
    h.read(root .. "/main.lua"))

  local selected
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    selected = items
    callback(nil)
  end
  vim.cmd("AIChatClose")
  vim.wait(50)
  h.truthy(vim.fn.isdirectory(isolated) == 1)
  h.truthy(buffer("aichatter-composer") ~= nil)
  vim.ui.select = function(items, _, callback)
    selected = items
    callback("Keep reviewing")
  end
  vim.cmd("AIChatClose")
  vim.wait(50)
  h.truthy(vim.fn.isdirectory(isolated) == 1)
  h.truthy(buffer("aichatter-composer") ~= nil)
  vim.ui.select = function(items, _, callback)
    selected = items
    callback("Discard pending changes")
  end
  vim.cmd("AIChatClose")
  h.truthy(h.wait_for(function()
    return vim.fn.isdirectory(isolated) == 0 and vim.fn.filereadable(exit_marker) == 1
      and #buffers("aichatter-composer") == 0
  end, 5000))
  h.eq({ "Keep reviewing", "Discard pending changes" }, selected)
  h.eq(0, #buffers("aichatter-composer"))
  vim.ui.select = old_select
  vim.env.TMPDIR = old_tmpdir
  vim.env.AICHATTER_FAKE_EXIT_MARKER = old_exit_marker
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end)

h.test("opens the managed browser login URL without handling credentials", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local opened
  local old_open = vim.ui.open
  vim.ui.open = function(url)
    opened = url
    return true
  end
  configure(root, "account-required")
  vim.cmd("AIChatLogin")
  h.truthy(h.wait_for(function() return opened ~= nil and status_is("idle") end, 5000))
  h.eq("https://chatgpt.com/auth", opened)
  vim.ui.open = old_open
  close_chat()
end)

h.test("AIChatToggle hides and restores the same chat", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  configure(root, "authenticated")

  h.eq(2, vim.fn.exists(":AIChatToggle"))
  vim.cmd("AIChatToggle")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  local composer = assert(buffer("aichatter-composer"))
  vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "draft" })

  vim.cmd("AIChatToggle")
  h.eq(nil, window_for(composer))
  vim.cmd("AIChatToggle")
  h.truthy(window_for(composer))
  h.eq("draft", h.buffer_text(composer))

  close_chat()
end)

h.test("AIChatModel picker displays and selects an available model", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local old_select = vim.ui.select
  configure(root, "authenticated")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("gpt-5.6-sol") end, 5000))
  vim.ui.select = function(items, opts, callback)
    h.eq("Select AI Chatter model", opts.prompt)
    h.eq("gpt-5.6-sol", items[1].id)
    h.eq("gpt-5.6-terra", items[2].id)
    callback(items[2])
  end

  vim.cmd("AIChatModel")

  h.truthy(h.wait_for(function() return status_is("gpt-5.6-terra") end, 3000))
  h.matches("Model: gpt%-5%.6%-terra", composer_metadata())
  h.matches("Reasoning: medium", composer_metadata())
  vim.ui.select = old_select
  close_chat()
end)

h.test("AIChatReasoning picker displays and uses a supported effort", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local old_select = vim.ui.select
  configure(root, "authenticated")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function()
    return composer_metadata():find("Reasoning: low", 1, true) ~= nil
  end, 5000))
  vim.ui.select = function(items, opts, callback)
    h.eq("Select AI Chatter reasoning", opts.prompt)
    h.eq("low", items[1].reasoningEffort)
    h.eq("high", items[2].reasoningEffort)
    callback(items[2])
  end

  vim.cmd("AIChatReasoning")

  h.truthy(h.wait_for(function()
    return composer_metadata():find("Reasoning: high", 1, true) ~= nil
  end, 3000))
  submit("Use deeper reasoning")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  vim.ui.select = old_select
  close_chat()
end)

h.test("AIChatModel argument displays and uses the model for the next turn", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  configure(root, "model-selection")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))

  vim.cmd("AIChatModel gpt-5.6-terra")
  h.truthy(status_is("gpt-5.6-terra"))
  submit("Use Terra")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))

  close_chat()
end)

h.test("routes an explicit command approval decision through the sidebar", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local selections = 0
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    selections = selections + 1
    h.eq({ "Approve once", "Decline" }, items)
    callback("Approve once")
  end
  configure(root, "command-approval")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  submit("run tests")
  h.truthy(h.wait_for(function()
    local transcript = buffer("aichatter-transcript")
    return transcript and h.buffer_text(transcript):find("Approval · decided", 1, true)
      and status_is("idle")
  end, 5000))
  h.eq(1, selections)
  vim.ui.select = old_select
  close_chat()
end)

h.test("cancels one active turn through the public command", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local temp_parent = h.tempdir()
  local old_tmpdir = vim.env.TMPDIR
  vim.env.TMPDIR = temp_parent
  configure(root, "wait-for-cancel")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  submit("wait")
  h.truthy(h.wait_for(function() return status_is("running") end, 3000))
  vim.cmd("AIChatCancel")
  local isolated
  h.truthy(h.wait_for(function()
    isolated = session_root(temp_parent)
    return isolated and status_is("idle")
  end, 5000))
  h.truthy(vim.fn.filereadable(
    isolated .. "/control/fake-app-server-interrupted") == 1)
  close_chat()
  vim.env.TMPDIR = old_tmpdir
end)

h.test("does not report a startup cancellation as an error when the chat closes", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local messages = {}
  local old_notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = tostring(message)
  end
  configure(root, "authenticated")

  vim.cmd("AIChat")
  vim.cmd("AIChatClose")

  h.truthy(h.wait_for(function()
    return #buffers("aichatter-composer") == 0
  end, 3000))
  vim.notify = old_notify
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  h.falsy(table.concat(messages, "\n"):find("session closing", 1, true))
end)

h.test("restarts the fake process once and preserves the visible session", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  local temp_parent = h.tempdir()
  local old_tmpdir = vim.env.TMPDIR
  vim.env.TMPDIR = temp_parent
  configure(root, "crash-once")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  submit("crash once")
  h.truthy(h.wait_for(function()
    local isolated = session_root(temp_parent)
    local transcript = buffer("aichatter-transcript")
    return isolated and vim.fn.filereadable(
      isolated .. "/control/fake-app-server-crashed") == 1
      and transcript and h.buffer_text(transcript):find("exited unexpectedly", 1, true)
      and status_is("idle")
  end, 6000))
  close_chat()
  vim.env.TMPDIR = old_tmpdir
end)

h.test("adds only contained regular files and exact visual lines", function()
  local root = h.git_project({
    ["main.lua"] = "one\ntwo\nthree\n",
    ["lua/extra.lua"] = "return 1\n",
  })
  local external = h.tempdir()
  h.write(external .. "/secret.lua", "return 'secret'\n")
  h.symlink(external, root .. "/link")
  local live = h.load_buffer(root .. "/main.lua", { "one", "two", "three" }, false)
  vim.api.nvim_set_current_buf(live)
  configure(root, "authenticated")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  vim.cmd("AIChatAddFile lua/extra.lua")
  local function add_visual(keys)
    vim.api.nvim_set_current_buf(live)
    vim.api.nvim_feedkeys(
      vim.keycode(keys .. ":AIChatAddSelection<CR>"), "xt", false)
    vim.wait(50)
  end
  add_visual("ggVj")
  add_visual("2gg0vj$")
  add_visual("gg0<C-v>2j$")
  local composer = assert(buffer("aichatter-composer"))
  local rendered = vim.inspect(vim.api.nvim_buf_get_extmarks(
    composer, -1, 0, -1, { details = true }))
  h.matches("@lua/extra.lua", rendered)
  h.matches("main.lua:1%-2", rendered)
  h.matches("main.lua:2%-3", rendered)
  h.matches("main.lua:1%-3", rendered)

  local notified
  local old_notify = vim.notify
  vim.notify = function(message) notified = message end
  vim.cmd("AIChatAddFile ../outside.lua")
  h.matches("outside project root", notified)
  notified = nil
  vim.cmd("AIChatAddFile link/secret.lua")
  h.matches("symlink", notified or "")
  rendered = vim.inspect(vim.api.nvim_buf_get_extmarks(
    composer, -1, 0, -1, { details = true }))
  h.falsy(rendered:find("@link/secret.lua", 1, true))
  vim.notify = old_notify

  local offered
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    offered = items
    callback("main.lua")
  end
  vim.cmd("AIChatAddFile")
  h.eq({ "lua/extra.lua", "main.lua" }, offered)
  vim.ui.select = old_select
  close_chat()
end)

h.test("refreshes crash-after-write proposals and continues in the restarted process", function()
  local root = h.git_project({ ["main.lua"] = "base\n" })
  local temp_parent = h.tempdir()
  local old_tmpdir = vim.env.TMPDIR
  vim.env.TMPDIR = temp_parent
  configure(root, "crash-after-write")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))

  submit("crash after writing")
  local changes = assert(buffer("aichatter-changes"))
  h.truthy(h.wait_for(function()
    return h.buffer_text(changes):find("main.lua", 1, true) ~= nil
      and status_is("reviewable")
  end, 6000))
  local isolated = assert(session_root(temp_parent), "session directory not found")
  h.eq("partial\n", h.read(isolated .. "/workspace/main.lua"))
  h.eq("base\n", h.read(root .. "/main.lua"))

  vim.api.nvim_set_current_win(assert(window_for(changes)))
  h.invoke_mapping(changes, "n", "<CR>")
  local diff_buf = assert(buffer("aichatter-diff"), "diff buffer not found")
  h.matches("%+partial", h.buffer_text(diff_buf))

  submit("revise the partial result")
  h.truthy(h.wait_for(function()
    return h.read(isolated .. "/workspace/main.lua") == "followup\n"
      and h.buffer_text(diff_buf):find("+followup", 1, true) ~= nil
      and status_is("reviewable")
  end, 6000))
  h.eq("base\n", h.read(root .. "/main.lua"))

  local old_select = vim.ui.select
  vim.ui.select = function(_, _, callback) callback("Discard pending changes") end
  vim.cmd("AIChatClose")
  h.truthy(h.wait_for(function()
    return vim.fn.isdirectory(isolated) == 0 and #buffers("aichatter-composer") == 0
  end, 5000))
  vim.ui.select = old_select
  vim.env.TMPDIR = old_tmpdir
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end)

h.test("AIChat retries a failed session instead of only toggling the view", function()
  local root = h.git_project({ ["main.lua"] = "return true\n" })
  configure(root, "unsupported-sandbox")
  vim.cmd("AIChat")
  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  submit("fail on unsupported sandbox")
  h.truthy(h.wait_for(function() return status_is("failed") end, 5000))

  vim.cmd("AIChat")

  h.truthy(h.wait_for(function() return status_is("idle") end, 5000))
  close_chat()
end)
