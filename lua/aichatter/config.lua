local M = {}
local current

local defaults = {
  side = "right",
  width = 0.35,
  composer_height = 0.20,
  codex_cmd = { "codex", "app-server", "--listen", "stdio://" },
  mappings = {
    submit = "<CR>",
    submit_alt = "<M-CR>",
    queue = "<Tab>",
    newline = "<C-j>",
    model = "<M-m>",
    reasoning = "<M-r>",
    open = "o",
    accept = "a",
    reject = "r",
    accept_remaining = "A",
    reject_remaining = "R",
    edit = "e",
    previous_hunk = "[c",
    next_hunk = "]c",
  },
}

local function validate(value)
  assert(value.side == "right", "side must be right in v1")
  assert(value.width > 0 and value.width < 1, "width must be between 0 and 1")
  assert(value.composer_height > 0 and value.composer_height < 1,
    "composer_height must be between 0 and 1")
end

function M.setup(opts)
  current = vim.tbl_deep_extend("force", {}, defaults, opts or {})
  validate(current)
  return current
end

function M.get()
  return current or M.setup()
end

return M
