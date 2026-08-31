local M = {}

function M.new(on_value, on_error)
  local self = { buffer = "" }

  function self:push(chunk)
    self.buffer = self.buffer .. (chunk or "")

    while true do
      local newline = self.buffer:find("\n", 1, true)
      if not newline then
        return
      end

      local line = self.buffer:sub(1, newline - 1)
      self.buffer = self.buffer:sub(newline + 1)
      if line ~= "" then
        local ok, value = pcall(vim.json.decode, line)
        if ok then
          on_value(value)
        elseif on_error then
          on_error(value, line)
        end
      end
    end
  end

  function self:finish()
    if self.buffer ~= "" and on_error then
      on_error("unterminated JSONL frame", self.buffer)
    end
    self.buffer = ""
  end

  return self
end

return M
