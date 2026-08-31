local default_diff = require("aichatter.diff")

local function new(dependencies)
  dependencies = dependencies or {}
  local M = {}
  local uv = dependencies.uv or vim.uv or vim.loop
  local schedule = dependencies.schedule or vim.schedule
  local diff = dependencies.diff or default_diff

  local function error_value(err)
    if type(err) == "table" then
      return err
    end
    return { message = tostring(err) }
  end

  local function check(value, err, code, operation, target)
    if value == nil then
      error({
        code = code,
        message = string.format("%s %s: %s", operation, target, err or "unknown error"),
      }, 0)
    end
    return value
  end

  local function read_file(target, size)
    local fd, open_err, open_code = uv.fs_open(target, "r", 0)
    check(fd, open_err, open_code, "open", target)
    local chunks = {}
    local offset = 0
    local ok, result = xpcall(function()
      while offset < size do
        local bytes, read_err, read_code = uv.fs_read(fd, math.min(65536, size - offset), offset)
        check(bytes, read_err, read_code, "read", target)
        if bytes == "" then
          break
        end
        chunks[#chunks + 1] = bytes
        offset = offset + #bytes
      end
      return table.concat(chunks)
    end, function(err) return err end)
    uv.fs_close(fd)
    if not ok then
      error(result, 0)
    end
    return result
  end

  local function scan_directory(job, absolute, relative)
    local handle, scan_err, scan_code = uv.fs_scandir(absolute)
    check(handle, scan_err, scan_code, "scan", absolute)
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if name ~= ".git" then
        job.queue[#job.queue + 1] = {
          absolute = absolute .. "/" .. name,
          relative = relative == "" and name or relative .. "/" .. name,
        }
      end
    end
  end

  local function scan_entry(job, entry)
    local stat, stat_err, stat_code = uv.fs_lstat(entry.absolute)
    check(stat, stat_err, stat_code, "lstat", entry.absolute)
    if stat.type == "directory" then
      scan_directory(job, entry.absolute, entry.relative)
    elseif stat.type == "link" then
      local target, link_err, link_code = uv.fs_readlink(entry.absolute)
      check(target, link_err, link_code, "readlink", entry.absolute)
      job.entries[entry.relative] = { kind = "link", target = target }
    elseif stat.type == "file" then
      local bytes = read_file(entry.absolute, stat.size)
      job.entries[entry.relative] = {
        kind = "file",
        size = #bytes,
        mode = bit.band(stat.mode, 511),
        digest = vim.fn.sha256(bytes),
        binary = diff.is_binary(bytes),
      }
    else
      error({ message = "unsupported file type at " .. entry.absolute }, 0)
    end
  end

  function M.scan(root, opts, callback)
    opts = opts or {}
    callback = callback or function() end
    root = root:gsub("/+$", "")
    local job = {
      callback = callback,
      cancel = opts.cancel or {},
      entries = {},
      finished = false,
      next_entry = 1,
      queue = { { absolute = root, relative = "" } },
    }

    local function finish(err, value)
      if job.finished then
        return
      end
      job.finished = true
      pcall(job.callback, err, value)
    end

    local run_batch
    run_batch = function()
      if job.finished then
        return
      end
      local processed = 0
      while processed < 128 and job.next_entry <= #job.queue do
        if job.cancel.cancelled then
          finish({ code = "cancelled", message = "manifest scan cancelled" })
          return
        end
        local entry = job.queue[job.next_entry]
        job.next_entry = job.next_entry + 1
        local ok, err = xpcall(function()
          scan_entry(job, entry)
        end, function(value) return value end)
        if not ok then
          finish(error_value(err))
          return
        end
        processed = processed + 1
      end

      if job.cancel.cancelled then
        finish({ code = "cancelled", message = "manifest scan cancelled" })
      elseif job.next_entry > #job.queue then
        finish(nil, job.entries)
      else
        schedule(run_batch)
      end
    end

    schedule(run_batch)
  end

  local function same_entry(before, after)
    if before.kind ~= after.kind then
      return false
    end
    if before.kind == "file" then
      return before.digest == after.digest and before.mode == after.mode
    end
    return before.kind == "link" and before.target == after.target
  end

  local function sorted_union(base, candidate)
    local included = {}
    local paths = {}
    for path in pairs(base) do
      included[path] = true
      paths[#paths + 1] = path
    end
    for path in pairs(candidate) do
      if not included[path] then
        paths[#paths + 1] = path
      end
    end
    table.sort(paths)
    return paths
  end

  function M.compare(base, candidate)
    local result = {}
    for _, relative in ipairs(sorted_union(base, candidate)) do
      local before, after = base[relative], candidate[relative]
      if not before then
        result[relative] = { path = relative, kind = "created", after = after }
      elseif not after then
        result[relative] = { path = relative, kind = "deleted", before = before }
      elseif not same_entry(before, after) then
        result[relative] = {
          path = relative,
          kind = "modified",
          before = before,
          after = after,
        }
      end
    end
    return result
  end

  return M
end

local manifest = new()
manifest._new = new
return manifest
