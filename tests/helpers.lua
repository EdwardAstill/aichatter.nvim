local M = {}
local cases = {}
local temporary_directories = {}

function M.test(name, fn)
  table.insert(cases, { name = name, fn = fn })
end

function M.eq(expected, actual)
  assert(expected == actual, string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
end

function M.truthy(value)
  assert(value, "expected truthy value")
end

function M.falsy(value)
  assert(not value, "expected falsy value")
end

function M.matches(pattern, value)
  assert(string.match(value, pattern), string.format("expected %s to match %s", value, pattern))
end

function M.raises(pattern, fn)
  local ok, err = pcall(fn)
  assert(not ok, "expected function to raise an error")
  M.matches(pattern, err)
end

function M.wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms, predicate, 10)
end

function M.tempdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  table.insert(temporary_directories, path)
  return path
end

function M.read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

function M.write(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  file:close()
end

function M.mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1)
end

function M.symlink(target, path)
  assert(vim.loop.fs_symlink(target, path))
end

function M.run()
  local failed = false

  for _, case in ipairs(cases) do
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
      print("PASS " .. case.name)
    else
      failed = true
      print("FAIL " .. case.name)
      print(err)
    end
  end

  for _, path in ipairs(temporary_directories) do
    vim.fn.delete(path, "rf")
  end

  if failed then
    vim.cmd("cquit 1")
  else
    vim.cmd("qa!")
  end
end

return M
