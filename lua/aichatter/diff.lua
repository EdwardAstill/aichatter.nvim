local M = {}

function M.is_binary(bytes)
  return bytes:find("\0", 1, true) ~= nil
end

function M.lines(bytes)
  local result = {
    lines = {},
    endofline = #bytes > 0 and bytes:sub(-1) == "\n",
  }
  local start = 1
  while start <= #bytes do
    local newline = bytes:find("\n", start, true)
    if not newline then
      result.lines[#result.lines + 1] = bytes:sub(start)
      break
    end
    result.lines[#result.lines + 1] = bytes:sub(start, newline - 1)
    start = newline + 1
  end
  return result
end

local function zero_start(start, count)
  if count == 0 then
    return start
  end
  return start - 1
end

local function slice(lines, start, count)
  local result = {}
  for index = start + 1, start + count do
    result[#result + 1] = lines[index]
  end
  return result
end

function M.hunks(base_bytes, candidate_bytes)
  if M.is_binary(base_bytes) or M.is_binary(candidate_bytes) then
    return { binary = true }
  end

  local base = M.lines(base_bytes)
  local candidate = M.lines(candidate_bytes)
  local indices = vim.diff(base_bytes, candidate_bytes, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
  })
  local hunks = {}
  for id, index in ipairs(indices) do
    local base_start = zero_start(index[1], index[2])
    local candidate_start = zero_start(index[3], index[4])
    local hunk = {
      id = id,
      base_start = base_start,
      base_count = index[2],
      candidate_start = candidate_start,
      candidate_count = index[4],
      base_lines = slice(base.lines, base_start, index[2]),
      candidate_lines = slice(candidate.lines, candidate_start, index[4]),
      base_endofline = base.endofline,
      candidate_endofline = candidate.endofline,
      status = "pending",
    }
    if base_bytes == "" and candidate_bytes ~= "" then
      hunk.file_creation = true
    elseif candidate_bytes == "" and base_bytes ~= "" then
      hunk.file_deletion = true
    end
    hunks[#hunks + 1] = hunk
  end
  return hunks
end

return M
