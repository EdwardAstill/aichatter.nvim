local h = require("tests.helpers")
local diff = require("aichatter.diff")

h.test("marks only NUL-containing bytes as binary", function()
  h.truthy(diff.is_binary("abc\0def"))
  h.falsy(diff.is_binary(""))
  h.falsy(diff.is_binary("a\r\nb\r\n"))
end)

h.test("splits lines while preserving final-newline state", function()
  h.eq({ lines = {}, endofline = false }, diff.lines(""))
  h.eq({ lines = { "a", "b" }, endofline = true }, diff.lines("a\nb\n"))
  h.eq({ lines = { "a", "b" }, endofline = false }, diff.lines("a\nb"))
  h.eq({ lines = { "a\r", "b\r" }, endofline = true }, diff.lines("a\r\nb\r\n"))
end)

h.test("returns two independent hunks for nearby non-adjacent edits", function()
  local hunks = diff.hunks("a\nb\nc\nd\n", "a\nB\nc\nD\n")

  h.eq(2, #hunks)
  h.eq({ "b" }, hunks[1].base_lines)
  h.eq({ "B" }, hunks[1].candidate_lines)
  h.eq({ "d" }, hunks[2].base_lines)
  h.eq({ "D" }, hunks[2].candidate_lines)
  h.eq(1, hunks[1].id)
  h.eq(2, hunks[2].id)
end)

h.test("uses stable zero-based ranges for replacements", function()
  local hunk = diff.hunks("a\nb\nc\n", "a\nB\nc\n")[1]

  h.eq({
    id = 1,
    base_start = 1,
    base_count = 1,
    candidate_start = 1,
    candidate_count = 1,
    base_lines = { "b" },
    candidate_lines = { "B" },
    base_endofline = true,
    candidate_endofline = true,
    status = "pending",
  }, hunk)
end)

h.test("uses stable zero-based ranges for insertions at start and end", function()
  local at_start = diff.hunks("a\nb\n", "x\na\nb\n")[1]
  local at_end = diff.hunks("a\nb\n", "a\nb\ny\n")[1]

  h.eq(0, at_start.base_start)
  h.eq(0, at_start.base_count)
  h.eq(0, at_start.candidate_start)
  h.eq({ "x" }, at_start.candidate_lines)
  h.eq(2, at_end.base_start)
  h.eq(0, at_end.base_count)
  h.eq(2, at_end.candidate_start)
  h.eq({ "y" }, at_end.candidate_lines)
end)

h.test("uses stable zero-based ranges for line deletions", function()
  local from_start = diff.hunks("a\nb\n", "b\n")[1]
  local from_end = diff.hunks("a\nb\n", "a\n")[1]

  h.eq(0, from_start.base_start)
  h.eq(1, from_start.base_count)
  h.eq(0, from_start.candidate_start)
  h.eq(0, from_start.candidate_count)
  h.eq({ "a" }, from_start.base_lines)
  h.eq(1, from_end.base_start)
  h.eq(1, from_end.base_count)
  h.eq(1, from_end.candidate_start)
  h.eq({}, from_end.candidate_lines)
end)

h.test("keeps adjacent replacements in one actionable hunk", function()
  local hunks = diff.hunks("a\nb\nc\nd\n", "a\nB\nC\nd\n")

  h.eq(1, #hunks)
  h.eq(1, hunks[1].base_start)
  h.eq(2, hunks[1].base_count)
  h.eq({ "b", "c" }, hunks[1].base_lines)
  h.eq({ "B", "C" }, hunks[1].candidate_lines)
end)

h.test("preserves a final-newline-only change in hunk metadata", function()
  local removed = diff.hunks("a\n", "a")[1]
  local added = diff.hunks("a", "a\n")[1]

  h.eq({ "a" }, removed.base_lines)
  h.eq({ "a" }, removed.candidate_lines)
  h.truthy(removed.base_endofline)
  h.falsy(removed.candidate_endofline)
  h.falsy(added.base_endofline)
  h.truthy(added.candidate_endofline)
end)

h.test("preserves CRLF bytes in copied hunk lines", function()
  local hunk = diff.hunks("a\r\nb\r\n", "a\r\nB\r\n")[1]

  h.eq({ "b\r" }, hunk.base_lines)
  h.eq({ "B\r" }, hunk.candidate_lines)
  h.truthy(hunk.base_endofline)
  h.truthy(hunk.candidate_endofline)
end)

h.test("returns an insertion hunk for a created text file", function()
  local hunks = diff.hunks("", "one\ntwo\n")

  h.eq(1, #hunks)
  h.truthy(hunks[1].file_creation)
  h.eq(0, hunks[1].base_start)
  h.eq(0, hunks[1].base_count)
  h.eq(0, hunks[1].candidate_start)
  h.eq(2, hunks[1].candidate_count)
  h.eq({ "one", "two" }, hunks[1].candidate_lines)
end)

h.test("returns one whole-file deletion record for a deleted text file", function()
  local hunks = diff.hunks("one\ntwo\n", "")

  h.eq(1, #hunks)
  h.truthy(hunks[1].file_deletion)
  h.eq(0, hunks[1].base_start)
  h.eq(2, hunks[1].base_count)
  h.eq(0, hunks[1].candidate_start)
  h.eq(0, hunks[1].candidate_count)
  h.eq({ "one", "two" }, hunks[1].base_lines)
end)

h.test("returns no hunks for equal empty files", function()
  h.eq({}, diff.hunks("", ""))
end)

h.test("returns file-level records without text hunks for binary changes", function()
  local modified = diff.hunks("a\0old", "a\0new")
  local created = diff.hunks("", "a\0new")
  local deleted = diff.hunks("a\0old", "")

  h.eq({ binary = true }, modified)
  h.eq({ binary = true }, created)
  h.eq({ binary = true }, deleted)
end)
