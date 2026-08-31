local h = require("tests.helpers")

h.test("uses the approved layout defaults", function()
  package.loaded["aichatter.config"] = nil
  local config = require("aichatter.config")
  local value = config.setup()
  h.eq("right", value.side)
  h.eq(0.35, value.width)
  h.eq(0.20, value.composer_height)
end)

h.test("rejects invalid ratios", function()
  local config = require("aichatter.config")
  h.raises("width must be between 0 and 1", function()
    config.setup({ width = 2 })
  end)
end)
