if vim.g.loaded_aichatter == 1 then return end
vim.g.loaded_aichatter = 1
require("aichatter")._register_commands()
