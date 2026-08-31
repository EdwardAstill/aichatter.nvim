local test_path = vim.env.TEST
local specs

if test_path and test_path ~= "" then
  specs = { test_path }
else
  specs = vim.fn.globpath("tests", "*_spec.lua", false, true)
  table.sort(specs)
end

for _, spec in ipairs(specs) do
  dofile(spec)
end

require("tests.helpers").run()
