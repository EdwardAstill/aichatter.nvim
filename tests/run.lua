local test_path = vim.env.TEST
local specs

if test_path and test_path ~= "" then
  specs = { test_path }
else
  specs = vim.fn.globpath("tests", "*_spec.lua", false, true)
  table.sort(specs)
end

local load_failed = false
for _, spec in ipairs(specs) do
  local ok, err = xpcall(function()
    dofile(spec)
  end, debug.traceback)
  if not ok then
    load_failed = true
    print("FAIL " .. spec)
    print(err)
  end
end

if load_failed then
  vim.cmd("cquit 1")
  return
end

require("tests.helpers").run()
