local path = require("aichatter.path")

local Context = {}
Context.__index = Context

local function relative_file(root, value)
  local normalized = path.normalize(value, root)
  assert(normalized ~= root, "context path must name a file")
  assert(path.is_within(root, normalized), "context path is outside project root")
  return normalized, path.relative(root, normalized)
end

local function source_fence(lines)
  local longest = 0
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return string.rep("`", math.max(3, longest + 1))
end

function Context.new(root)
  return setmetatable({
    root = path.normalize(root),
    files = {},
    file_set = {},
    selections = {},
  }, Context)
end

function Context:add_file(value)
  local normalized, relative = relative_file(self.root, value)
  if not self.file_set[normalized] then
    self.file_set[normalized] = true
    self.files[#self.files + 1] = relative
  end
  return self
end

function Context:add_buffer(bufnr)
  assert(type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr),
    "buffer must be valid")
  assert(vim.api.nvim_buf_is_loaded(bufnr), "buffer must be loaded")
  local name = vim.api.nvim_buf_get_name(bufnr)
  assert(name ~= "", "buffer must have a name")
  return self:add_file(name)
end

function Context:add_selection(value, first, last, lines)
  assert(type(first) == "number" and first % 1 == 0 and first >= 1,
    "selection first line must be a positive one-based integer")
  assert(type(last) == "number" and last % 1 == 0 and last >= first,
    "selection last line must be at or after the first line")
  assert(type(lines) == "table", "selection lines must be a table")
  local _, relative = relative_file(self.root, value)
  local copied = {}
  for index, line in ipairs(lines) do
    assert(type(line) == "string", "selection lines must contain strings")
    copied[index] = line
  end
  self.selections[#self.selections + 1] = {
    path = relative,
    first = first,
    last = last,
    lines = copied,
  }
  return self
end

function Context:inputs(text)
  assert(type(text) == "string", "prompt text must be a string")
  local inputs = { { type = "text", text = text } }
  for _, relative in ipairs(self.files) do
    inputs[#inputs + 1] = { type = "text", text = "@" .. relative }
  end
  for _, selection in ipairs(self.selections) do
    local fence = source_fence(selection.lines)
    inputs[#inputs + 1] = {
      type = "text",
      text = string.format(
        "%s lines %d-%d\n%s\n%s\n%s",
        selection.path,
        selection.first,
        selection.last,
        fence,
        table.concat(selection.lines, "\n"),
        fence
      ),
    }
  end
  return inputs
end

function Context:clear()
  self.files = {}
  self.file_set = {}
  self.selections = {}
end

return Context
