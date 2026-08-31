local h = require("tests.helpers")
local path = require("aichatter.path")

h.test("normalizes a relative path against an explicit base", function()
  h.eq("/tmp/project/file.lua", path.normalize("src/../file.lua", "/tmp/project"))
  h.eq("/tmp/project/file.lua", path.join("/tmp/project", "src", "..", "file.lua"))
  h.eq("src/file.lua", path.relative("/tmp/project", "/tmp/project/src/file.lua"))
end)

h.test("rejects sibling paths that share a string prefix", function()
  h.truthy(path.is_within("/tmp/project", "/tmp/project/file.lua"))
  h.falsy(path.is_within("/tmp/project", "/tmp/project-old/file.lua"))
end)

h.test("finds a git project root from a nested directory", function()
  local root = h.tempdir()
  local nested = root .. "/one/two"
  h.mkdir(nested)
  local result = vim.system({ "git", "init", "--quiet", root }, { text = true }):wait()
  h.eq(0, result.code)
  h.eq(path.normalize(root), path.project_root(nested))
end)

h.test("uses the normalized start directory outside a git project", function()
  local root = h.tempdir()
  local nested = root .. "/one/two"
  h.mkdir(nested)
  h.eq(path.normalize(nested), path.project_root(nested .. "/."))
end)

h.test("uses an injected process boundary for project-root fallback", function()
  local calls = 0
  local isolated = path._new({
    system = function()
      calls = calls + 1
      error("git unavailable")
    end,
  })

  h.eq("/tmp/project", isolated.project_root("/tmp/project/./"))
  h.eq(1, calls)
end)
