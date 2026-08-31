local function is_absolute(value)
  return value:sub(1, 1) == "/"
end

local function components(value)
  local result = {}
  for component in value:gmatch("[^/]+") do
    result[#result + 1] = component
  end
  return result
end

local function new(dependencies)
  dependencies = dependencies or {}
  local uv = dependencies.uv or vim.uv or vim.loop
  local system = dependencies.system or vim.system
  local M = {}

  function M.normalize(value, base)
    assert(type(value) == "string" and value ~= "", "path must be a non-empty string")
    value = vim.fs.normalize(value)
    if is_absolute(value) then
      return value
    end

    base = base or assert(uv.cwd())
    base = vim.fs.normalize(base)
    if not is_absolute(base) then
      base = vim.fs.normalize(assert(uv.cwd()) .. "/" .. base)
    end
    return vim.fs.normalize(base .. "/" .. value)
  end

  function M.join(...)
    local parts = { ... }
    assert(#parts > 0, "path.join requires at least one path")
    return M.normalize(table.concat(parts, "/"))
  end

  function M.relative(parent, child)
    local parent_parts = components(M.normalize(parent))
    local child_parts = components(M.normalize(child))
    local common = 0
    while parent_parts[common + 1] == child_parts[common + 1]
      and parent_parts[common + 1] ~= nil do
      common = common + 1
    end

    local result = {}
    for _ = common + 1, #parent_parts do
      result[#result + 1] = ".."
    end
    for index = common + 1, #child_parts do
      result[#result + 1] = child_parts[index]
    end
    return #result == 0 and "." or table.concat(result, "/")
  end

  function M.is_within(parent, child)
    parent, child = M.normalize(parent), M.normalize(child)
    if parent == child then
      return true
    end
    local prefix = parent:sub(-1) == "/" and parent or parent .. "/"
    return child:sub(1, #prefix) == prefix
  end

  function M.project_root(start)
    start = M.normalize(start)
    local ok, process = pcall(system, {
      "git", "-C", start, "rev-parse", "--show-toplevel",
    }, { text = true })
    if not ok then
      return start
    end

    local waited, result = pcall(function()
      return process:wait()
    end)
    if not waited or result.code ~= 0 then
      return start
    end

    local root = vim.trim(result.stdout or "")
    return root ~= "" and M.normalize(root) or start
  end

  return M
end

local M = new()
M._new = new
return M
