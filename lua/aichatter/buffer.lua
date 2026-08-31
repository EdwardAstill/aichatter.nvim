local M = {}

local function is_zero_byte_loaded_buffer(bufnr)
  local ok, offset = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.line2byte(vim.fn.line("$"))
  end)
  return ok and offset == -1
end

function M.bytes(bufnr, opts)
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if opts.empty_is_zero and #lines == 1 and lines[1] == "" then
    return ""
  end
  local bytes = table.concat(lines, "\n")
  if not vim.bo[bufnr].endofline then return bytes end
  if #lines == 1 and lines[1] == "" and is_zero_byte_loaded_buffer(bufnr) then
    return ""
  end
  return bytes .. "\n"
end

return M
