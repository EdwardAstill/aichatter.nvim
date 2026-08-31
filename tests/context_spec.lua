local h = require("tests.helpers")
local Context = require("aichatter.context")

h.test("builds prompt inputs from text, file, and visual selection", function()
  local context = Context.new("/project")
  context:add_file("/project/lua/main.lua")
  context:add_selection("/project/lua/main.lua", 5, 8,
    { "local x = 1", "return x" })

  local inputs = context:inputs("Explain this")

  h.eq({ type = "text", text = "Explain this" }, inputs[1])
  h.eq({ type = "text", text = "@lua/main.lua" }, inputs[2])
  h.eq({
    type = "text",
    text = "lua/main.lua lines 5-8\n```\nlocal x = 1\nreturn x\n```",
  }, inputs[3])
end)

h.test("normalizes and deduplicates files while preserving selection order", function()
  local context = Context.new("/project/./src/..")
  context:add_file("lua/../lua/main.lua")
  context:add_file("/project/lua/main.lua")
  context:add_selection("lua/second.lua", 9, 9, { "second" })
  context:add_selection("lua/first.lua", 2, 3, { "first", "next" })

  local inputs = context:inputs("Review")

  h.eq(4, #inputs)
  h.eq("@lua/main.lua", inputs[2].text)
  h.matches("lua/second%.lua lines 9%-9", inputs[3].text)
  h.matches("lua/first%.lua lines 2%-3", inputs[4].text)
end)

h.test("rejects file and selection paths outside the project root", function()
  local context = Context.new("/project")

  h.raises("outside project root", function()
    context:add_file("/other/main.lua")
  end)
  h.raises("outside project root", function()
    context:add_selection("../secret", 1, 1, { "secret" })
  end)
  h.raises("must name a file", function()
    context:add_file("/project")
  end)
end)

h.test("requires explicit one-based selection ranges", function()
  local context = Context.new("/project")

  h.raises("positive one%-based", function()
    context:add_selection("main.lua", 0, 1, { "bad" })
  end)
  h.raises("last line", function()
    context:add_selection("main.lua", 4, 3, { "bad" })
  end)
  h.raises("lines must be a table", function()
    context:add_selection("main.lua", 1, 1, "bad")
  end)
end)

h.test("adds a named buffer as normalized file context", function()
  local root = h.tempdir()
  local bufnr = h.load_buffer(root .. "/lua/buffer.lua", { "return true" }, true)
  local context = Context.new(root)

  context:add_buffer(bufnr)

  h.eq("@lua/buffer.lua", context:inputs("Inspect")[2].text)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("rejects unnamed and unloaded buffers", function()
  local context = Context.new("/project")
  local unnamed = vim.api.nvim_create_buf(false, true)
  local unloaded = vim.fn.bufadd("/project/unloaded.lua")

  h.raises("buffer must be loaded", function() context:add_buffer(unloaded) end)
  h.raises("buffer must have a name", function() context:add_buffer(unnamed) end)

  vim.api.nvim_buf_delete(unnamed, { force = true })
  vim.api.nvim_buf_delete(unloaded, { force = true })
end)

h.test("clears all one-shot file and selection context", function()
  local context = Context.new("/project")
  context:add_file("main.lua")
  context:add_selection("main.lua", 1, 1, { "line" })

  context:clear()

  h.eq({ { type = "text", text = "Again" } }, context:inputs("Again"))
end)
