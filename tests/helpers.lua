local M = {}
local cases = {}
local temporary_directories = {}

function M.test(name, fn)
  table.insert(cases, { name = name, fn = fn })
end

function M.eq(expected, actual)
  assert(vim.deep_equal(expected, actual),
    string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
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

function M.scan_changes(base, candidate)
  local manifest = require("aichatter.manifest")
  local before, after
  local before_error, after_error
  manifest.scan(base, {}, function(err, value)
    before_error, before = err, value
  end)
  manifest.scan(candidate, {}, function(err, value)
    after_error, after = err, value
  end)
  assert(M.wait_for(function()
    return before_error ~= nil or after_error ~= nil or (before ~= nil and after ~= nil)
  end, 2000), "timed out scanning manifests")
  assert(not before_error, vim.inspect(before_error))
  assert(not after_error, vim.inspect(after_error))
  return manifest.compare(before, after)
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

function M.read_optional(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
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

function M.chmod(path, mode)
  assert(vim.uv.fs_chmod(path, mode))
end

function M.mode(path)
  local stat = assert(vim.uv.fs_stat(path))
  return bit.band(stat.mode, 511)
end

function M.assert_no_error(err)
  assert(err == nil, vim.inspect(err))
end

function M.load_buffer(filename, lines, modified)
  local bufnr = vim.fn.bufadd(filename)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = modified
  return bufnr
end

function M.await(invoke)
  local calls = 0
  local values
  invoke(function(...)
    calls = calls + 1
    values = { ... }
  end)
  assert(M.wait_for(function() return calls > 0 end, 3000), "timed out waiting for callback")
  vim.wait(20)
  return values and unpack(values) or nil, calls
end

function M.review_fixture(base_bytes, candidate_bytes, opts)
  opts = opts or {}
  local baseline_root = M.tempdir()
  local workspace_root = M.tempdir()
  local live_root = M.tempdir()
  local relative = opts.path or "main.txt"

  local function replace(root, bytes)
    local filename = root .. "/" .. relative
    if bytes == nil then
      vim.fn.delete(filename)
      return
    end
    M.mkdir(vim.fs.dirname(filename))
    M.write(filename, bytes)
  end

  replace(baseline_root, base_bytes)
  replace(workspace_root, candidate_bytes)
  replace(live_root, opts.live_bytes == nil and base_bytes or opts.live_bytes)
  if opts.base_mode and base_bytes ~= nil then
    M.chmod(baseline_root .. "/" .. relative, opts.base_mode)
  end
  if opts.candidate_mode and candidate_bytes ~= nil then
    M.chmod(workspace_root .. "/" .. relative, opts.candidate_mode)
  end
  if opts.live_mode and M.read_optional(live_root .. "/" .. relative) ~= nil then
    M.chmod(live_root .. "/" .. relative, opts.live_mode)
  end

  local Live = require("aichatter.live")
  local Review = require("aichatter.review")
  local live = Live.new(live_root)
  local live_write_count = 0
  local original_write = live.write
  function live:write(...)
    live_write_count = live_write_count + 1
    return original_write(self, ...)
  end
  local review = Review.new({
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live = live,
  })
  local refresh_err, refresh_calls = M.await(function(callback)
    review:refresh(callback)
  end)
  assert(refresh_err == nil, vim.inspect(refresh_err))
  assert(refresh_calls == 1, "refresh callback called more than once")

  return {
    baseline_root = baseline_root,
    workspace_root = workspace_root,
    live_root = live_root,
    relative = relative,
    live = live,
    review = review,
    baseline_bytes = function() return M.read_optional(baseline_root .. "/" .. relative) end,
    workspace_bytes = function() return M.read_optional(workspace_root .. "/" .. relative) end,
    live_bytes = function() return live:read(relative) end,
    set_live = function(bytes) replace(live_root, bytes) end,
    set_workspace = function(bytes) replace(workspace_root, bytes) end,
    live_write_count = function() return live_write_count end,
  }
end

local function git(root, ...)
  local argv = { "git", "-C", root, ... }
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, string.format(
    "%s failed (%d): %s",
    table.concat(argv, " "),
    result.code,
    result.stderr or ""
  ))
end

function M.git_project(files)
  local root = M.tempdir()
  git(root, "init", "--quiet")
  git(root, "config", "user.name", "aichatter tests")
  git(root, "config", "user.email", "aichatter@example.invalid")
  for relative, bytes in pairs(files or {}) do
    local parent = vim.fs.dirname(root .. "/" .. relative)
    M.mkdir(parent)
    M.write(root .. "/" .. relative, bytes)
  end
  git(root, "add", "--all")
  git(root, "commit", "--quiet", "-m", "fixture")
  return root
end

function M.create_shadow(root, opts)
  opts = vim.tbl_extend("force", {
    root = root,
    temp_parent = M.tempdir(),
  }, opts or {})
  local Shadow = require("aichatter.shadow")
  local value, failure
  Shadow.create(opts, function(err, result)
    failure, value = err, result
  end)
  assert(M.wait_for(function() return failure ~= nil or value ~= nil end, 3000),
    "timed out creating shadow workspace")
  assert(not failure, vim.inspect(failure))
  return value
end

function M.fake_transport(responses)
  local listeners = {}
  local transport = { responded = {} }

  function transport:request(method, params, callback)
    self.responded[#self.responded + 1] = { method = method, params = params }
    local response = responses[method]
    if type(response) == "function" then
      response(params, callback)
      return
    end
    callback(nil, response)
  end

  function transport:on(method, listener)
    listeners[method] = listeners[method] or {}
    listeners[method][#listeners[method] + 1] = listener
  end

  function transport:off(method, listener)
    local method_listeners = listeners[method] or {}
    for index, current in ipairs(method_listeners) do
      if current == listener then
        table.remove(method_listeners, index)
        return
      end
    end
  end

  function transport:emit(method, params)
    local method_listeners = listeners[method] or {}
    for _, listener in ipairs(vim.list_slice(method_listeners)) do
      listener(params)
    end
  end

  return transport
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
