local h = require("tests.helpers")

h.test("renders semantic transcript entries including errors and approvals", function()
  local view = require("aichatter.ui.transcript").new({})
  view:render({
    { type = "user", text = "Please fix it" },
    { type = "assistant", text = "Working" },
    { type = "activity", status = "completed", item = { type = "commandExecution", command = "make test" } },
    { type = "error", error = { message = "Codex stopped" } },
    { type = "approval", request_id = 7, status = "pending", request = { command = "curl example.com" } },
  })
  local text = h.buffer_text(view.bufnr)
  h.matches("Please fix it", text)
  h.matches("Working", text)
  h.matches("completed", text)
  h.matches("make test", text)
  h.matches("Codex stopped", text)
  h.matches("Approval", text)
  h.matches("curl example.com", text)
  view:close()
end)

h.test("coalesces assistant delta rendering once per event-loop tick", function()
  local scheduled = {}
  local view = require("aichatter.ui.transcript").new({
    schedule = function(callback) scheduled[#scheduled + 1] = callback end,
  })
  view:assistant_delta("stream")
  view:assistant_delta("ed")
  view:assistant_delta(" reply")
  h.eq(1, #scheduled)
  h.eq("", h.buffer_text(view.bufnr))
  scheduled[1]()
  h.matches("streamed reply", h.buffer_text(view.bufnr))
  h.eq(1, view.render_count)
  view:close()
end)

h.test("appends activity and error entries without losing prior transcript", function()
  local view = require("aichatter.ui.transcript").new({})
  view:append({ type = "user", text = "first" })
  view:append({ type = "activity", status = "started", item = { type = "commandExecution" } })
  view:append({ type = "error", error = { message = "failure" } })
  local text = h.buffer_text(view.bufnr)
  h.matches("first", text)
  h.matches("started", text)
  h.matches("failure", text)
  view:close()
  view:close()
end)
