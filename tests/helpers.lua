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

function M.buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.invoke_mapping(bufnr, mode, lhs)
  vim.api.nvim_set_current_buf(bufnr)
  if mode == "i" then vim.cmd("startinsert") end
  local keys = vim.keycode(lhs)
  if mode == "i" and vim.api.nvim_get_mode().mode ~= "i" then
    keys = "i" .. keys
  end
  vim.api.nvim_feedkeys(keys, "mx", false)
  vim.wait(50)
  if mode == "i" then vim.cmd("stopinsert") end
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
  if opts.review_dependencies then
    Review = Review._new(opts.review_dependencies)
  end
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

function M.fake_review(record)
  record = record or {}
  record.path = record.path or "main.lua"
  record.base = record.base or ""
  record.candidate = record.candidate or ""
  record.base_exists = record.base_exists ~= false
  record.candidate_exists = record.candidate_exists ~= false
  record.binary = record.binary or false
  record.file_level = record.file_level or false
  record.hunks = record.hunks or require("aichatter.diff").hunks(
    record.base, record.candidate)
  for index, hunk in ipairs(record.hunks) do
    hunk.id = hunk.id or index
    hunk.status = hunk.status or "pending"
  end

  local review = {
    record = record,
    accepted_hunks = {},
    rejected_hunks = {},
    edited_candidates = {},
  }

  function review:files()
    return { self.record }
  end

  function review:accept_hunk(path, id, callback)
    M.eq(self.record.path, path)
    self.accepted_hunks[#self.accepted_hunks + 1] = id
    if callback then callback() end
  end

  function review:reject_hunk(path, id, callback)
    M.eq(self.record.path, path)
    self.rejected_hunks[#self.rejected_hunks + 1] = id
    if callback then callback() end
  end

  function review:edit_candidate(path, bytes, callback)
    M.eq(self.record.path, path)
    self.edited_candidates[#self.edited_candidates + 1] = bytes
    if self.edit_error then
      callback(self.edit_error)
      return
    end
    self.record.candidate = bytes
    self.record.hunks = require("aichatter.diff").hunks(self.record.base, bytes)
    for index, hunk in ipairs(self.record.hunks) do
      hunk.id = index
      hunk.status = "pending"
    end
    callback()
  end

  return review
end

function M.has_highlight(marks, group)
  for _, mark in ipairs(marks or {}) do
    local details = mark[4] or {}
    if details.hl_group == group then return true end
  end
  return false
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
  responses = responses or {}
  local listeners = {}
  local transport = {
    responded = {},
    requests = {},
    responses = {},
    starts = 0,
    stops = 0,
    next_id = 1,
  }

  local function resolve(response, params, callback)
    if type(response) == "function" then
      response(params, callback)
    else
      callback(nil, response)
    end
  end

  function transport:start(callback)
    self.starts = self.starts + 1
    resolve(responses.__start, nil, callback or function() end)
  end

  function transport:stop(callback)
    self.stops = self.stops + 1
    resolve(responses.__stop, nil, callback or function() end)
  end

  function transport:request(method, params, callback)
    self.responded[#self.responded + 1] = { method = method, params = params }
    local id = self.next_id
    self.next_id = id + 1
    self.requests[#self.requests + 1] = { id = id, method = method, params = params }
    resolve(responses[method], params, callback or function() end)
    return id
  end

  function transport:respond(id, result, err)
    self.responses[id] = { result = result, error = err }
    return true
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

  function transport:emit(method, params, id)
    local method_listeners = listeners[method] or {}
    for _, listener in ipairs(vim.list_slice(method_listeners)) do
      listener(params, id)
    end
  end

  function transport:server_request(id, method, params)
    self:emit(method, params, id)
  end

  function transport:listener_count(method)
    return #(listeners[method] or {})
  end

  function transport:total_listener_count()
    local count = 0
    for _, method_listeners in pairs(listeners) do
      count = count + #method_listeners
    end
    return count
  end

  return transport
end

function M.session_fixture(opts)
  opts = opts or {}
  local Context = require("aichatter.context")
  local Session = require("aichatter.session")
  local responses = vim.tbl_extend("force", {
    ["turn/start"] = { turn = { id = "turn-1" } },
    ["turn/steer"] = {},
    ["turn/interrupt"] = {},
    ["thread/start"] = { thread = { id = "thread-restarted" } },
  }, opts.responses or {})
  local transport = M.fake_transport(responses)
  local files = opts.files
  if files == nil then
    files = { { path = "main.lua", status = "pending" } }
  end
  local review = opts.review or {
    refresh_count = 0,
    sync_count = 0,
    refresh = function(self, callback)
      self.refresh_count = self.refresh_count + 1
      callback(nil)
    end,
    sync_live = function(self, callback)
      self.sync_count = self.sync_count + 1
      callback(nil)
    end,
    files = function()
      return files
    end,
  }
  local shadow = opts.shadow or {
    project_root = "/project",
    baseline_root = "/shadow/control/baseline",
    workspace_root = "/shadow/workspace",
    cleanup_count = 0,
    cleanup = function(self, callback)
      self.cleanup_count = self.cleanup_count + 1
      callback()
    end,
    validate_grant_root = function(self, value)
      value = value or self.workspace_root
      return value == self.workspace_root
        or require("aichatter.path").is_within(self.workspace_root, value)
    end,
  }
  local events = {}
  local context = opts.context or Context.new(shadow.project_root)
  local session = Session.new({
    transport = transport,
    auth = opts.auth,
    review = review,
    shadow = shadow,
    context = context,
    emit = function(name, value)
      events[#events + 1] = { name = name, value = value }
    end,
  })
  session.state = opts.state or "idle"
  session.thread_id = opts.thread_id or "thread-1"
  session.turn_id = opts.turn_id
  session.started = true
  return {
    session = session,
    transport = transport,
    review = review,
    shadow = shadow,
    context = context,
    events = events,
    set_files = function(value) files = value end,
  }
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
