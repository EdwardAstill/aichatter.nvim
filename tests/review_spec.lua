local h = require("tests.helpers")

local function call(invoke)
  local err, value, calls
  local callback_calls = 0
  invoke(function(callback_err, callback_value)
    callback_calls = callback_calls + 1
    err, value = callback_err, callback_value
  end)
  assert(h.wait_for(function() return callback_calls > 0 end, 3000), "timed out waiting for review")
  vim.wait(20)
  calls = callback_calls
  h.eq(1, calls)
  return err, value
end

local function action(fixture, method, ...)
  local args = { ... }
  return call(function(callback)
    args[#args + 1] = callback
    fixture.review[method](fixture.review, unpack(args))
  end)
end

h.test("refresh exposes proposals without changing live bytes", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local file = fixture.review:files()[1]

  h.eq("old\n", fixture.live_bytes())
  h.eq("main.txt", file.path)
  h.eq("pending", file.status)
  h.eq("old\n", file.base)
  h.eq("new\n", file.candidate)
  h.eq(1, #file.hunks)
end)

h.test("accepts one hunk and rejects another by stable id", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local first, second = unpack(fixture.review:files()[1].hunks)

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", first.id))
  h.eq(second.id, fixture.review:files()[1].hunks[2].id)
  h.eq("accepted", fixture.review:files()[1].hunks[1].status)
  h.eq(nil, action(fixture, "reject_hunk", "main.txt", second.id))

  h.eq("a\nB\nc\nd\n", fixture.live_bytes())
  h.eq("a\nB\nc\nd\n", fixture.workspace_bytes())
end)

h.test("marks an overlapping live edit as conflict without writing", function()
  local fixture = h.review_fixture("a\nb\n", "a\nB\n")
  fixture.set_live("a\nuser edit\n")

  local err = action(fixture, "accept_hunk", "main.txt", 1)

  h.eq("conflict", err.code)
  h.eq("conflict", fixture.review:files()[1].status)
  h.eq("conflict", fixture.review:files()[1].hunks[1].status)
  h.eq(0, fixture.live_write_count())
  h.eq("a\nuser edit\n", fixture.live_bytes())
end)

h.test("accept preserves and reconciles a non-overlapping live edit", function()
  local base = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
  local fixture = h.review_fixture(base, "1\nTWO\n3\n4\n5\n6\n7\n8\n9\n10\n")
  fixture.set_live("1\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.live_bytes())
  h.eq("1\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.baseline_bytes())
  h.eq("1\nTWO\n3\n4\n5\n6\n7\n8\n9\nTEN\n", fixture.workspace_bytes())
end)

h.test("sync_live incorporates safe edits and reports overlapping paths", function()
  local safe = h.review_fixture("a\nb\nc\n", "a\nB\nc\n")
  safe.set_live("a\nb\nC\n")
  h.eq(nil, action(safe, "sync_live"))
  h.eq("a\nb\nC\n", safe.baseline_bytes())
  h.eq("a\nB\nC\n", safe.workspace_bytes())

  local conflict = h.review_fixture("a\nb\n", "a\nB\n")
  conflict.set_live("a\nuser\n")
  local err = action(conflict, "sync_live")
  h.eq("conflict", err.code)
  h.eq({ "main.txt" }, err.paths)
  h.eq("a\nb\n", conflict.baseline_bytes())
  h.eq("a\nB\n", conflict.workspace_bytes())
  h.eq("conflict", conflict.review:files()[1].status)
end)

h.test("refresh preserves decisions and ids only for identical hunks", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local first_id = fixture.review:files()[1].hunks[1].id
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", first_id))

  h.eq(nil, action(fixture, "refresh"))
  h.eq(first_id, fixture.review:files()[1].hunks[1].id)
  h.eq("accepted", fixture.review:files()[1].hunks[1].status)

  fixture.set_workspace("a\nBee\nc\nD\n")
  h.eq(nil, action(fixture, "refresh"))
  h.truthy(first_id ~= fixture.review:files()[1].hunks[1].id)
  h.eq("pending", fixture.review:files()[1].hunks[1].status)
end)

h.test("edit_candidate recomputes candidate hunks without touching live", function()
  local fixture = h.review_fixture("a\nb\n", "a\nB\n")
  local old_id = fixture.review:files()[1].hunks[1].id

  h.eq(nil, action(fixture, "edit_candidate", "main.txt", "A\nb\n"))

  h.eq("a\nb\n", fixture.live_bytes())
  h.eq("A\nb\n", fixture.workspace_bytes())
  h.truthy(old_id ~= fixture.review:files()[1].hunks[1].id)
  h.eq({ "a" }, fixture.review:files()[1].hunks[1].base_lines)
  h.eq({ "A" }, fixture.review:files()[1].hunks[1].candidate_lines)
end)

h.test("accept_file and reject_file iterate only pending hunks", function()
  local accepted = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  local hunks = accepted.review:files()[1].hunks
  h.eq(nil, action(accepted, "accept_hunk", "main.txt", hunks[1].id))
  accepted.set_live("a\nuser-after-accept\nc\nd\n")
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("a\nuser-after-accept\nc\nD\n", accepted.live_bytes())

  local rejected = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  hunks = rejected.review:files()[1].hunks
  h.eq(nil, action(rejected, "accept_hunk", "main.txt", hunks[1].id))
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq("a\nB\nc\nd\n", rejected.live_bytes())
  h.eq("a\nB\nc\nd\n", rejected.workspace_bytes())
end)

h.test("accepts a created text file hunk including an empty baseline", function()
  local fixture = h.review_fixture(nil, "created\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("created\n", fixture.live_bytes())
  h.eq(nil, fixture.baseline_bytes())
end)

h.test("requires a whole-file action before accepting a text deletion", function()
  local fixture = h.review_fixture("deleted\n", nil)

  local err = action(fixture, "accept_hunk", "main.txt", 1)
  h.eq("file_action_required", err.code)
  h.eq("deleted\n", fixture.live_bytes())
  h.eq(nil, action(fixture, "accept_file", "main.txt"))
  h.eq(nil, fixture.live_bytes())
  h.eq(nil, fixture.baseline_bytes())
end)

h.test("accepts and rejects empty-file creation as a file-level action", function()
  local accepted = h.review_fixture(nil, "")
  h.truthy(accepted.review:files()[1].file_level)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("", accepted.live_bytes())
  h.eq("", accepted.baseline_bytes())

  local rejected = h.review_fixture(nil, "")
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq(nil, rejected.workspace_bytes())
  h.eq(nil, rejected.live_bytes())
end)

h.test("accepts and rejects binary files at file level", function()
  local accepted = h.review_fixture("old\0bytes", "new\0bytes")
  local file = accepted.review:files()[1]
  h.truthy(file.binary)
  h.eq(0, #file.hunks)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq("new\0bytes", accepted.live_bytes())
  h.eq("new\0bytes", accepted.baseline_bytes())

  local rejected = h.review_fixture("old\0bytes", "new\0bytes")
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq("old\0bytes", rejected.workspace_bytes())
  h.eq("old\0bytes", rejected.live_bytes())
end)

h.test("mode-only changes use file-level accept and reject", function()
  local accepted = h.review_fixture("same\n", "same\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  local file = accepted.review:files()[1]
  h.truthy(file.mode_only)
  h.truthy(file.file_level)
  h.eq(nil, action(accepted, "accept_file", "main.txt"))
  h.eq(493, h.mode(accepted.live_root .. "/main.txt"))
  h.eq(493, h.mode(accepted.baseline_root .. "/main.txt"))

  local rejected = h.review_fixture("same\n", "same\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  h.eq(nil, action(rejected, "reject_file", "main.txt"))
  h.eq(420, h.mode(rejected.workspace_root .. "/main.txt"))
  h.eq(420, h.mode(rejected.live_root .. "/main.txt"))
end)

h.test("accepts a final-newline-only proposal", function()
  local fixture = h.review_fixture("line", "line\n")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("line\n", fixture.live_bytes())
end)

h.test("accepting into a loaded unsaved buffer leaves disk untouched", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/main.txt", { "old" }, true)
  vim.bo[bufnr].endofline = true

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq({ "new" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].modified)
  h.eq("old\n", h.read(fixture.live_root .. "/main.txt"))
  h.eq("new\n", fixture.live_bytes())
end)

h.test("accounts for an earlier accepted insertion when applying a later hunk", function()
  local fixture = h.review_fixture(
    "a\nb\nc\nd\n",
    "inserted\na\nb\nc\nD\n"
  )
  local hunks = fixture.review:files()[1].hunks
  h.eq(2, #hunks)

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", hunks[1].id))
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", hunks[2].id))

  h.eq("inserted\na\nb\nc\nD\n", fixture.live_bytes())
end)

h.test("accept_file applies a pending mode change after text hunks", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })

  h.eq(nil, action(fixture, "accept_file", "main.txt"))

  h.eq("new\n", fixture.live_bytes())
  h.eq(493, h.mode(fixture.live_root .. "/main.txt"))
  h.eq(493, h.mode(fixture.baseline_root .. "/main.txt"))
end)

h.test("reject_file rejects a pending mode change after text hunks", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })

  h.eq(nil, action(fixture, "reject_file", "main.txt"))

  h.eq("old\n", fixture.workspace_bytes())
  h.eq(420, h.mode(fixture.workspace_root .. "/main.txt"))
  h.eq("old\n", fixture.live_bytes())
end)

h.test("sync_live conflicts when live and candidate both change mode", function()
  local fixture = h.review_fixture("old\n", "new\n", {
    base_mode = 420, candidate_mode = 493, live_mode = 420,
  })
  h.chmod(fixture.live_root .. "/main.txt", 448)

  local err = action(fixture, "sync_live")

  h.eq("conflict", err.code)
  h.eq({ "main.txt" }, err.paths)
  h.eq(420, h.mode(fixture.baseline_root .. "/main.txt"))
  h.eq(493, h.mode(fixture.workspace_root .. "/main.txt"))
end)

h.test("reconciles a live final-newline edit around an accepted insertion", function()
  local fixture = h.review_fixture("a\nb\n", "inserted\na\nb\n")
  fixture.set_live("a\nb")

  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))

  h.eq("inserted\na\nb", fixture.live_bytes())
  h.eq("a\nb", fixture.baseline_bytes())
  h.eq("inserted\na\nb", fixture.workspace_bytes())
  h.eq("accepted", fixture.review:files()[1].hunks[1].status)
end)

h.test("sync_live advances an accepted proposal out of review", function()
  local fixture = h.review_fixture("old\n", "new\n")
  h.eq(nil, action(fixture, "accept_hunk", "main.txt", 1))
  h.eq("accepted", fixture.review:files()[1].status)

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("new\n", fixture.baseline_bytes())
  h.eq("new\n", fixture.workspace_bytes())
  h.eq({}, fixture.review:files())
end)

h.test("sync_live copies an unsaved loaded edit for a non-proposal file", function()
  local fixture = h.review_fixture("old\n", "new\n")
  h.write(fixture.baseline_root .. "/other.txt", "disk\n")
  h.write(fixture.workspace_root .. "/other.txt", "disk\n")
  h.write(fixture.live_root .. "/other.txt", "disk\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/other.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = true
  h.eq(nil, action(fixture, "refresh"))

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("unsaved\n", h.read(fixture.baseline_root .. "/other.txt"))
  h.eq("unsaved\n", h.read(fixture.workspace_root .. "/other.txt"))
  h.eq("disk\n", h.read(fixture.live_root .. "/other.txt"))
end)

h.test("sync_live leaves an untouched pending binary proposal reviewable", function()
  local fixture = h.review_fixture("old\0bytes", "new\0bytes")

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("old\0bytes", fixture.baseline_bytes())
  h.eq("new\0bytes", fixture.workspace_bytes())
  h.eq("pending", fixture.review:files()[1].status)
end)

h.test("sync_live discovers a new file that exists only in a loaded buffer", function()
  local fixture = h.review_fixture("old\n", "new\n")
  local bufnr = h.load_buffer(fixture.live_root .. "/new-buffer.txt", { "unsaved" }, true)
  vim.bo[bufnr].endofline = true

  h.eq(nil, action(fixture, "sync_live"))

  h.eq("unsaved\n", h.read(fixture.baseline_root .. "/new-buffer.txt"))
  h.eq("unsaved\n", h.read(fixture.workspace_root .. "/new-buffer.txt"))
  h.eq(nil, h.read_optional(fixture.live_root .. "/new-buffer.txt"))
end)
