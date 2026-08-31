local default_diff = require("aichatter.diff")
local default_fs = require("aichatter.fs")
local default_manifest = require("aichatter.manifest")

local function once(callback)
  assert(type(callback) == "function", "callback function is required")
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    pcall(callback, ...)
  end
end

local function error_value(err)
  if type(err) == "table" then
    return err
  end
  return { message = tostring(err) }
end

local function replace_lines(lines, start, count, replacement)
  local result = {}
  for index = 1, start do
    result[#result + 1] = lines[index]
  end
  for _, line in ipairs(replacement) do
    result[#result + 1] = line
  end
  for index = start + count + 1, #lines do
    result[#result + 1] = lines[index]
  end
  return result
end

local function lines_bytes(lines, endofline)
  local bytes = table.concat(lines, "\n")
  if endofline then
    bytes = bytes .. "\n"
  end
  return bytes
end

local function same_lines(left, right)
  return vim.deep_equal(left, right)
end

local function slice(lines, start, count)
  local result = {}
  for index = start + 1, start + count do
    result[#result + 1] = lines[index]
  end
  return result
end

local function range_end(hunk)
  return hunk.base_start + hunk.base_count
end

local function overlaps(left, right)
  local left_end = range_end(left)
  local right_end = range_end(right)
  if left.base_count == 0 and right.base_count == 0 then
    return left.base_start == right.base_start
  elseif left.base_count == 0 then
    return left.base_start >= right.base_start and left.base_start <= right_end
  elseif right.base_count == 0 then
    return right.base_start >= left.base_start and right.base_start <= left_end
  end
  return left.base_start < right_end and right.base_start < left_end
end

local function hunk_key(hunk)
  local endofline_change
  if hunk.base_endofline ~= hunk.candidate_endofline then
    endofline_change = { hunk.base_endofline, hunk.candidate_endofline }
  end
  return vim.json.encode({
    hunk.base_start,
    hunk.base_count,
    hunk.candidate_start,
    hunk.candidate_count,
    hunk.base_lines,
    hunk.candidate_lines,
    endofline_change,
    hunk.file_creation or false,
    hunk.file_deletion or false,
  })
end

local function same_change(left, right)
  return left.base_start == right.base_start
    and left.base_count == right.base_count
    and left.candidate_count == right.candidate_count
    and same_lines(left.base_lines, right.base_lines)
    and same_lines(left.candidate_lines, right.candidate_lines)
    and left.base_endofline == right.base_endofline
    and left.candidate_endofline == right.candidate_endofline
end

local function entry_mode(entry)
  return entry and entry.kind == "file" and entry.mode or nil
end

local function sorted_keys(values)
  local result = {}
  for key in pairs(values) do
    result[#result + 1] = key
  end
  table.sort(result)
  return result
end

local function new(dependencies)
  dependencies = dependencies or {}
  local diff = dependencies.diff or default_diff
  local fs = dependencies.fs or default_fs
  local manifest = dependencies.manifest or default_manifest
  local schedule = dependencies.schedule or vim.schedule
  local uv = dependencies.uv or vim.uv or vim.loop
  local Review = {}
  Review.__index = Review

  local function failure(code, message)
    return { code = code, message = message }
  end

  local function open_flags()
    local constants = uv.constants or {}
    if type(constants.O_RDONLY) == "number" and type(constants.O_NOFOLLOW) == "number" then
      return bit.bor(constants.O_RDONLY, constants.O_NOFOLLOW)
    end
    return "r"
  end

  local function same_identity(left, right)
    return left and right and left.dev ~= nil and left.ino ~= nil
      and left.dev == right.dev and left.ino == right.ino
  end

  local function verified_read(root, relative, entry)
    if not entry or entry.kind ~= "file" then
      return nil
    end
    local target = root .. "/" .. relative
    local before, before_err, before_code = uv.fs_lstat(target)
    if not before then
      if before_code == "ENOENT" then
        error(failure("changed", "snapshot file disappeared: " .. target), 0)
      end
      error(failure(before_code, before_err or "could not stat " .. target), 0)
    end
    local before_mode = bit.band(before.mode, 511)
    if before.type ~= "file" or before.size ~= entry.size or before_mode ~= entry.mode then
      error(failure("changed", "snapshot identity changed: " .. target), 0)
    end
    local fd, open_err, open_code = uv.fs_open(target, open_flags(), 0)
    if not fd then
      error(failure(open_code, open_err or "could not open " .. target), 0)
    end
    local chunks = {}
    local ok, result = xpcall(function()
      local opened, stat_err, stat_code = uv.fs_fstat(fd)
      if not opened then error(failure(stat_code, stat_err or "could not stat " .. target), 0) end
      if not same_identity(before, opened) or opened.size ~= entry.size
        or bit.band(opened.mode, 511) ~= entry.mode then
        error(failure("changed", "snapshot file changed while opening: " .. target), 0)
      end
      local offset = 0
      while offset < opened.size do
        local bytes, read_err, read_code = uv.fs_read(fd, math.min(65536, opened.size - offset), offset)
        if bytes == nil then error(failure(read_code, read_err or "could not read " .. target), 0) end
        if bytes == "" then break end
        chunks[#chunks + 1] = bytes
        offset = offset + #bytes
      end
      return table.concat(chunks)
    end, function(err) return err end)
    local closed, close_err, close_code = uv.fs_close(fd)
    if not ok then error(result, 0) end
    if not closed then error(failure(close_code, close_err or "could not close " .. target), 0) end
    local after, after_err, after_code = uv.fs_lstat(target)
    if not after then
      error(failure(after_code == "ENOENT" and "changed" or after_code,
        after_err or "snapshot file disappeared: " .. target), 0)
    end
    if not same_identity(before, after) or after.size ~= entry.size
      or bit.band(after.mode, 511) ~= entry.mode or vim.fn.sha256(result) ~= entry.digest then
      error(failure("changed", "snapshot bytes changed: " .. target), 0)
    end
    return result
  end

  local function write_shadow(root, relative, bytes, mode, callback)
    callback = once(callback)
    local target = root .. "/" .. relative
    if bytes ~= nil then
      local ok, err = pcall(fs.atomic_write, target, bytes, mode or 420, callback)
      if not ok then
        callback(error_value(err))
      end
      return
    end
    schedule(function()
      local stat, stat_err, stat_code = uv.fs_lstat(target)
      if not stat then
        if stat_code == "ENOENT" then
          callback()
        else
          callback({ code = stat_code, message = stat_err or "could not stat " .. target })
        end
        return
      end
      if stat.type == "directory" then
        callback({ code = "is_directory", message = "refusing to delete directory " .. target })
        return
      end
      local removed, remove_err, remove_code = uv.fs_unlink(target)
      if removed then
        callback()
      else
        callback({ code = remove_code, message = remove_err or "could not unlink " .. target })
      end
    end)
  end

  local function shadow_operation(root, relative, next_exists, next_bytes, next_mode,
      previous_exists, previous_bytes, previous_mode)
    return {
      apply = function(done)
        write_shadow(root, relative, next_exists and next_bytes or nil, next_mode, done)
      end,
      rollback = function(done)
        write_shadow(root, relative, previous_exists and previous_bytes or nil, previous_mode, done)
      end,
    }
  end

  local function run_transaction(operations, callback)
    callback = once(callback)
    local applied = {}
    local index = 1
    local function rollback(original_err)
      local rollback_index = #applied
      local function restore(rollback_err)
        if rollback_err then
          callback({
            code = "rollback_failed",
            message = "mutation failed and rollback was incomplete",
            cause = original_err,
            rollback = rollback_err,
          })
          return
        end
        local operation = applied[rollback_index]
        rollback_index = rollback_index - 1
        if not operation then
          callback(original_err)
          return
        end
        local ok, thrown = pcall(operation.rollback, restore)
        if not ok then restore(error_value(thrown)) end
      end
      restore()
    end
    local function advance(err)
      if err then rollback(err); return end
      local operation = operations[index]
      index = index + 1
      if not operation then callback(); return end
      local ok, thrown = pcall(operation.apply, function(apply_err)
        if not apply_err then applied[#applied + 1] = operation end
        advance(apply_err)
      end)
      if not ok then advance(error_value(thrown)) end
    end
    advance()
  end

  function Review.new(opts)
    opts = opts or {}
    return setmetatable({
      baseline_root = assert(opts.baseline_root, "baseline_root is required"),
      workspace_root = assert(opts.workspace_root, "workspace_root is required"),
      live = assert(opts.live, "live is required"),
      _files = {},
      _by_path = {},
      _next_hunk_id = 1,
      _baseline_entries = {},
      _workspace_entries = {},
    }, Review)
  end

  function Review:files()
    return self._files
  end

  local function refresh_after_failure(self, original_err, callback)
    self:refresh(function(refresh_err)
      if refresh_err then
        callback({
          code = "recovery_refresh_failed",
          message = "mutation failed and review refresh also failed",
          cause = original_err,
          refresh = refresh_err,
        })
      else
        callback(original_err)
      end
    end)
  end

  local function restore_live(self, relative, before, after, callback)
    self.live:restore(relative, before, after, callback)
  end

  local function file_status(record)
    if record.file_level then
      return record.status or "pending"
    end
    local accepted, pending, rejected, conflict = 0, 0, 0, 0
    for _, hunk in ipairs(record.hunks) do
      if hunk.status == "accepted" then
        accepted = accepted + 1
      elseif hunk.status == "rejected" then
        rejected = rejected + 1
      elseif hunk.status == "conflict" then
        conflict = conflict + 1
      else
        pending = pending + 1
      end
    end
    if record.mode_changed then
      if record.mode_status == "conflict" then
        conflict = conflict + 1
      else
        pending = pending + 1
      end
    end
    if conflict > 0 then
      return "conflict"
    elseif pending > 0 and (accepted > 0 or rejected > 0) then
      return "partial"
    elseif pending > 0 then
      return "pending"
    elseif accepted > 0 and rejected == 0 then
      return "accepted"
    elseif rejected > 0 and accepted == 0 then
      return "rejected"
    elseif accepted > 0 or rejected > 0 then
      return "partial"
    end
    return "pending"
  end

  local function file_key(record)
    return vim.json.encode({
      record.kind,
      record.base_exists,
      record.candidate_exists,
      record.base,
      record.candidate,
      record.base_mode,
      record.candidate_mode,
      record.binary,
    })
  end

  function Review:_build_files(base_entries, workspace_entries)
    local changes = manifest.compare(base_entries, workspace_entries)
    local files, by_path = {}, {}
    for _, relative in ipairs(sorted_keys(changes)) do
      local change = changes[relative]
      local before, after = change.before, change.after
      local base_exists = before ~= nil
      local candidate_exists = after ~= nil
      local base = verified_read(self.baseline_root, relative, before)
      local candidate = verified_read(self.workspace_root, relative, after)
      local regular = (not before or before.kind == "file")
        and (not after or after.kind == "file")
      local binary = not regular
        or (base ~= nil and diff.is_binary(base))
        or (candidate ~= nil and diff.is_binary(candidate))
      local base_bytes = base or ""
      local candidate_bytes = candidate or ""
      local hunks = binary and {} or diff.hunks(base_bytes, candidate_bytes)
      if hunks.binary then
        binary, hunks = true, {}
      end
      local base_mode = entry_mode(before)
      local candidate_mode = entry_mode(after)
      local mode_changed = base_exists and candidate_exists and base_mode ~= candidate_mode
      local mode_only = mode_changed and base_bytes == candidate_bytes
      local file_level = binary or change.kind == "deleted" or mode_only
        or (#hunks == 0 and (change.kind == "created" or change.kind == "deleted"))
      local old = self._by_path[relative]
      local old_hunks = {}
      if old then
        for _, old_hunk in ipairs(old.hunks) do
          old_hunks[hunk_key(old_hunk)] = old_hunk
        end
      end
      for _, hunk in ipairs(hunks) do
        local previous = old_hunks[hunk_key(hunk)]
        if previous then
          hunk.id = previous.id
          hunk.status = previous.status
        else
          hunk.id = self._next_hunk_id
          self._next_hunk_id = self._next_hunk_id + 1
          hunk.status = "pending"
        end
      end
      local record = {
        path = relative,
        kind = change.kind,
        before = before,
        after = after,
        base_exists = base_exists,
        candidate_exists = candidate_exists,
        base = base_bytes,
        candidate = candidate_bytes,
        base_mode = base_mode,
        candidate_mode = candidate_mode,
        mode_changed = mode_changed,
        mode_only = mode_only,
        binary = binary,
        file_level = file_level,
        hunks = hunks,
      }
      if mode_changed then
        local same_mode_change = old
          and old.base_mode == base_mode
          and old.candidate_mode == candidate_mode
          and old.base == base_bytes
          and old.candidate == candidate_bytes
        record.mode_status = same_mode_change and old.mode_status or "pending"
      end
      if file_level and old and file_key(old) == file_key(record) then
        record.status = old.status
      end
      record.status = file_status(record)
      files[#files + 1] = record
      by_path[relative] = record
    end
    self._files = files
    self._by_path = by_path
    self._baseline_entries = base_entries
    self._workspace_entries = workspace_entries
  end

  function Review:refresh(callback)
    callback = once(callback)
    local base_entries, workspace_entries
    local remaining = 2
    local failed = false
    local function completed(err)
      if failed then return end
      if err then
        failed = true
        callback(err)
        return
      end
      remaining = remaining - 1
      if remaining ~= 0 then
        return
      end
      local ok, build_err = pcall(function()
        self:_build_files(base_entries, workspace_entries)
      end)
      if ok then
        callback()
      else
        callback(error_value(build_err))
      end
    end
    manifest.scan(self.baseline_root, {}, function(err, entries)
      if not err then
        base_entries = entries
      end
      completed(err)
    end)
    manifest.scan(self.workspace_root, {}, function(err, entries)
      if not err then
        workspace_entries = entries
      end
      completed(err)
    end)
  end

  function Review:_find_hunk(relative, id)
    local record = self._by_path[relative]
    if not record then
      return nil, nil, { code = "not_found", message = "unknown review path: " .. relative }
    end
    for _, hunk in ipairs(record.hunks) do
      if hunk.id == id then
        return record, hunk
      end
    end
    return record, nil, { code = "not_found", message = "unknown hunk id: " .. tostring(id) }
  end

  local function mark_conflict(record, hunk)
    if hunk then
      hunk.status = "conflict"
    end
    record.status = "conflict"
  end

  local function mapped_start(target, live_hunks)
    local offset = 0
    for _, live_hunk in ipairs(live_hunks) do
      if range_end(live_hunk) <= target.base_start then
        offset = offset + live_hunk.candidate_count - live_hunk.base_count
      end
    end
    return target.base_start + offset
  end

  local function applies_at_baseline(record, target, live_bytes, live_exists)
    if record.base_exists ~= live_exists and record.base == (live_bytes or "") then
      return nil, { code = "conflict", message = "live file presence changed" }
    end
    local live_hunks = diff.hunks(record.base, live_bytes or "")
    if live_hunks.binary then
      return nil, { code = "conflict", message = "live file became binary" }
    end
    for _, live_hunk in ipairs(live_hunks) do
      if overlaps(live_hunk, target) then
        return nil, { code = "conflict", message = "live edit overlaps proposed hunk" }
      end
    end
    local live = diff.lines(live_bytes or "")
    local start = mapped_start(target, live_hunks)
    if not same_lines(slice(live.lines, start, target.base_count), target.base_lines) then
      return nil, { code = "conflict", message = "live baseline slice changed" }
    end
    local base = diff.lines(record.base)
    if target.base_start + target.base_count == #base.lines
      and target.base_endofline ~= target.candidate_endofline
      and live.endofline ~= target.base_endofline then
      return nil, { code = "conflict", message = "live final newline changed" }
    end
    return { start = start, parsed = live, hunks = live_hunks }
  end

  local function apply_live_hunk(record, hunk, analysis)
    local lines = replace_lines(
      analysis.parsed.lines,
      analysis.start,
      hunk.base_count,
      hunk.candidate_lines
    )
    local endofline = analysis.parsed.endofline
    local base = diff.lines(record.base)
    if hunk.base_start + hunk.base_count == #base.lines
      and hunk.base_endofline ~= hunk.candidate_endofline then
      endofline = hunk.candidate_endofline
    end
    return lines_bytes(lines, endofline)
  end

  local function proposal_before(proposal, live_hunk)
    return range_end(proposal) <= live_hunk.base_start
  end

  local function proposal_start(live_hunk, proposals)
    local offset = 0
    for _, proposal in ipairs(proposals) do
      if proposal_before(proposal, live_hunk) then
        offset = offset + proposal.candidate_count - proposal.base_count
      end
    end
    return live_hunk.base_start + offset
  end

  local function apply_hunks(bytes, hunks, coordinate)
    local parsed = diff.lines(bytes)
    local endofline = parsed.endofline
    local target_count = #parsed.lines
    local ordered = {}
    for _, hunk in ipairs(hunks) do
      ordered[#ordered + 1] = hunk
    end
    table.sort(ordered, function(left, right)
      return coordinate(left) > coordinate(right)
    end)
    for _, hunk in ipairs(ordered) do
      local start, count, replacement = coordinate(hunk)
      parsed.lines = replace_lines(parsed.lines, start, count, replacement)
      if start + count == target_count
        and hunk.base_endofline ~= hunk.candidate_endofline then
        endofline = hunk.candidate_endofline
      end
    end
    return lines_bytes(parsed.lines, endofline)
  end

  local function overlaps_candidate(user_hunk, accepted_hunk)
    local left_start = user_hunk.base_start
    local left_count = user_hunk.base_count
    local right_start = accepted_hunk.candidate_start
    local right_count = accepted_hunk.candidate_count
    local left_end = left_start + left_count
    local right_end = right_start + right_count
    if left_count == 0 and right_count == 0 then return left_start == right_start end
    if left_count == 0 then return left_start >= right_start and left_start <= right_end end
    if right_count == 0 then return right_start >= left_start and right_start <= left_end end
    return left_start < right_end and right_start < left_end
  end

  function Review:_reconcile_after_accept(record, _, callback)
    local live_snapshot, snapshot_err = self.live:snapshot(record.path)
    if not live_snapshot then callback(snapshot_err); return end
    local accepted = {}
    for _, hunk in ipairs(record.hunks) do
      if hunk.status == "accepted" then accepted[#accepted + 1] = hunk end
    end
    local baseline_count = #diff.lines(record.base).lines
    local accepted_bytes = apply_hunks(record.base, accepted, function(hunk)
      return hunk.base_start, hunk.base_count, hunk.candidate_lines
    end, baseline_count)
    local accepted_changes = diff.hunks(record.base, accepted_bytes)
    local user_hunks = diff.hunks(accepted_bytes, live_snapshot.bytes or "")
    local outstanding = diff.hunks(accepted_bytes, record.candidate)
    if accepted_changes.binary or user_hunks.binary or outstanding.binary then
      callback({ code = "conflict", message = "live file became binary during reconciliation" })
      return
    end

    local accepted_override = false
    for _, user_hunk in ipairs(user_hunks) do
      for _, accepted_hunk in ipairs(accepted_changes) do
        if overlaps_candidate(user_hunk, accepted_hunk) then accepted_override = true end
      end
    end

    local safe = {}
    local baseline_coordinates = {}
    local workspace_coordinates = {}
    if accepted_override then
      local live_hunks = diff.hunks(record.base, live_snapshot.bytes or "")
      if live_hunks.binary then
        callback({ code = "conflict", message = "live file became binary during reconciliation" })
        return
      end
      for _, live_hunk in ipairs(live_hunks) do
        local accepted_match
        local overlapping_pending
        local overlapping_accepted
        for _, proposal in ipairs(record.hunks) do
          if proposal.status == "accepted" and same_change(live_hunk, proposal) then
            accepted_match = proposal
            break
          elseif overlaps(live_hunk, proposal) then
            if proposal.status == "pending" or proposal.status == "conflict" then
              overlapping_pending = proposal
            elseif proposal.status == "accepted"
              and live_hunk.base_start == proposal.base_start
              and live_hunk.base_count == proposal.base_count then
              overlapping_accepted = proposal
            end
          end
        end
        if overlapping_pending then
          mark_conflict(record, overlapping_pending)
        elseif not accepted_match then
          safe[#safe + 1] = live_hunk
          baseline_coordinates[live_hunk] = {
            live_hunk.base_start, live_hunk.base_count, live_hunk.candidate_lines,
          }
          if overlapping_accepted then
            workspace_coordinates[live_hunk] = {
              overlapping_accepted.candidate_start,
              overlapping_accepted.candidate_count,
              live_hunk.candidate_lines,
            }
          else
            workspace_coordinates[live_hunk] = {
              proposal_start(live_hunk, record.hunks),
              live_hunk.base_count,
              live_hunk.candidate_lines,
            }
          end
        end
      end
    else
      for _, user_hunk in ipairs(user_hunks) do
        local pending_overlap = false
        for _, proposal in ipairs(outstanding) do
          if overlaps(user_hunk, proposal) then pending_overlap = true end
        end
        if pending_overlap then
          for _, proposal in ipairs(record.hunks) do
            if proposal.status == "pending" or proposal.status == "conflict" then
              mark_conflict(record, proposal)
            end
          end
        else
          local inverse_offset = 0
          for _, accepted_hunk in ipairs(accepted_changes) do
            if accepted_hunk.candidate_start + accepted_hunk.candidate_count
              <= user_hunk.base_start then
              inverse_offset = inverse_offset
                + accepted_hunk.base_count - accepted_hunk.candidate_count
            end
          end
          safe[#safe + 1] = user_hunk
          baseline_coordinates[user_hunk] = {
            user_hunk.base_start + inverse_offset,
            user_hunk.base_count,
            user_hunk.candidate_lines,
          }
          workspace_coordinates[user_hunk] = {
            proposal_start(user_hunk, outstanding),
            user_hunk.base_count,
            user_hunk.candidate_lines,
          }
        end
      end
    end

    local live_mode = live_snapshot.mode or record.base_mode or record.candidate_mode or 420
    local mode_conflict = record.mode_changed and live_mode ~= record.base_mode
    if mode_conflict then
      record.mode_status = "conflict"
      record.status = "conflict"
    end
    local safe_mode_change = not record.mode_changed
      and record.base_exists and live_mode ~= record.base_mode
    if #safe == 0 and not safe_mode_change then
      callback()
      return
    end
    local new_base = apply_hunks(record.base, safe, function(hunk)
      return unpack(baseline_coordinates[hunk])
    end, baseline_count)
    local new_workspace = apply_hunks(record.candidate, safe, function(hunk)
      return unpack(workspace_coordinates[hunk])
    end, #diff.lines(accepted_bytes).lines)
    local base_mode = record.mode_changed and record.base_mode or live_mode
    local workspace_mode = record.mode_changed and record.candidate_mode or live_mode
    run_transaction({
      shadow_operation(
        self.baseline_root, record.path, true, new_base, base_mode,
        record.base_exists, record.base, record.base_mode or 420
      ),
      shadow_operation(
        self.workspace_root, record.path, true, new_workspace, workspace_mode,
        record.candidate_exists, record.candidate, record.candidate_mode or 420
      ),
    }, callback)
  end

  function Review:accept_hunk(relative, id, callback)
    callback = once(callback)
    local record, hunk, find_err = self:_find_hunk(relative, id)
    if not hunk then
      callback(find_err)
      return
    end
    if record.file_level or hunk.file_deletion then
      callback({ code = "file_action_required", message = "change requires a whole-file action" })
      return
    end
    if hunk.status == "accepted" or hunk.status == "rejected" then
      callback()
      return
    end
    local before, snapshot_err = self.live:snapshot(relative)
    if not before then
      callback(snapshot_err)
      return
    end
    local analysis, conflict_err = applies_at_baseline(record, hunk, before.bytes, before.exists)
    if not analysis then
      mark_conflict(record, hunk)
      callback(conflict_err)
      return
    end
    local accepted_bytes = apply_live_hunk(record, hunk, analysis)
    local live_mode = before.mode or record.candidate_mode or record.base_mode or 420
    self.live:write(relative, accepted_bytes, live_mode, before, function(write_err)
      if write_err then
        callback(write_err)
        return
      end
      local after, after_err = self.live:snapshot(relative)
      if not after then callback(after_err); return end
      hunk.status = "accepted"
      record.status = file_status(record)
      self:_reconcile_after_accept(record, analysis.hunks, function(reconcile_err)
        if reconcile_err then
          hunk.status = "pending"
          record.status = file_status(record)
          restore_live(self, relative, before, after, function(restore_err)
            refresh_after_failure(self, restore_err or reconcile_err, callback)
          end)
          return
        end
        self:refresh(callback)
      end)
    end)
  end

  local function reject_bytes(record, hunk)
    local candidate = diff.lines(record.candidate)
    candidate.lines = replace_lines(
      candidate.lines,
      hunk.candidate_start,
      hunk.candidate_count,
      hunk.base_lines
    )
    if hunk.candidate_start + hunk.candidate_count == #diff.lines(record.candidate).lines
      and hunk.base_endofline ~= hunk.candidate_endofline then
      candidate.endofline = hunk.base_endofline
    end
    return lines_bytes(candidate.lines, candidate.endofline)
  end

  function Review:reject_hunk(relative, id, callback)
    callback = once(callback)
    local record, hunk, find_err = self:_find_hunk(relative, id)
    if not hunk then
      callback(find_err)
      return
    end
    if record.file_level or hunk.file_deletion then
      callback({ code = "file_action_required", message = "change requires a whole-file action" })
      return
    end
    if hunk.status == "accepted" or hunk.status == "rejected" then
      callback()
      return
    end
    local bytes
    if not hunk.file_creation then
      bytes = reject_bytes(record, hunk)
    end
    local mode = record.candidate_mode or record.base_mode or 420
    write_shadow(self.workspace_root, relative, bytes, mode, function(write_err)
      if write_err then
        callback(write_err)
      else
        self:refresh(callback)
      end
    end)
  end

  function Review:edit_candidate(relative, bytes, callback)
    callback = once(callback)
    local record = self._by_path[relative]
    if not record then
      callback({ code = "not_found", message = "unknown review path: " .. relative })
      return
    end
    write_shadow(
      self.workspace_root,
      relative,
      bytes,
      record.candidate_mode or record.base_mode or 420,
      function(err)
        if err then
          callback(err)
        else
          self:refresh(callback)
        end
      end
    )
  end

  function Review:_accept_whole_file(record, callback)
    local before, snapshot_err = self.live:snapshot(record.path)
    if not before then callback(snapshot_err); return end
    if before.exists ~= record.base_exists or (before.bytes or "") ~= record.base
      or (record.base_exists and before.mode ~= record.base_mode) then
      mark_conflict(record)
      callback({ code = "conflict", message = "live file changed" })
      return
    end
    local function advance_baseline(live_err)
      if live_err then
        callback(live_err)
        return
      end
      local after, after_err = self.live:snapshot(record.path)
      if not after then callback(after_err); return end
      write_shadow(
        self.baseline_root,
        record.path,
        record.candidate_exists and record.candidate or nil,
        record.candidate_mode or record.base_mode or 420,
        function(baseline_err)
          if baseline_err then
            restore_live(self, record.path, before, after, function(restore_err)
              refresh_after_failure(self, restore_err or baseline_err, callback)
            end)
          else
            self:refresh(callback)
          end
        end
      )
    end
    if record.candidate_exists then
      self.live:write(
        record.path,
        record.candidate,
        record.candidate_mode or record.base_mode or 420,
        before,
        advance_baseline
      )
    else
      write_shadow(
        self.baseline_root,
        record.path,
        nil,
        record.base_mode or 420,
        function(baseline_err)
          if baseline_err then
            refresh_after_failure(self, baseline_err, callback)
            return
          end
          self.live:delete(record.path, before, function(live_err)
            if not live_err then self:refresh(callback); return end
            write_shadow(
              self.baseline_root,
              record.path,
              record.base,
              record.base_mode or 420,
              function(rollback_err)
                local reported = live_err
                if rollback_err then
                  reported = {
                    code = "rollback_failed",
                    message = "live deletion failed and baseline rollback was incomplete",
                    cause = live_err,
                    rollback = rollback_err,
                  }
                end
                refresh_after_failure(self, reported, callback)
              end
            )
          end)
        end
      )
    end
  end

  function Review:_accept_mode(record, callback)
    callback = once(callback)
    local before, snapshot_err = self.live:snapshot(record.path)
    if not before then callback(snapshot_err); return end
    local accepted = {}
    for _, hunk in ipairs(record.hunks) do
      if hunk.status == "accepted" then accepted[#accepted + 1] = hunk end
    end
    local accepted_bytes = apply_hunks(record.base, accepted, function(hunk)
      return hunk.base_start, hunk.base_count, hunk.candidate_lines
    end, #diff.lines(record.base).lines)
    if not before.exists or before.mode ~= record.base_mode or before.bytes ~= accepted_bytes then
      record.mode_status = "conflict"
      record.status = "conflict"
      callback({ code = "conflict", message = "live file mode changed" })
      return
    end
    self.live:write(record.path, before.bytes, record.candidate_mode, before, function(live_err)
      if live_err then
        callback(live_err)
        return
      end
      local after, after_err = self.live:snapshot(record.path)
      if not after then callback(after_err); return end
      write_shadow(
        self.baseline_root,
        record.path,
        record.base,
        record.candidate_mode,
        function(baseline_err)
          if baseline_err then
            record.mode_status = "pending"
            restore_live(self, record.path, before, after, function(restore_err)
              refresh_after_failure(self, restore_err or baseline_err, callback)
            end)
          else
            self:refresh(callback)
          end
        end
      )
    end)
  end

  function Review:_reject_mode(record, callback)
    callback = once(callback)
    write_shadow(
      self.workspace_root,
      record.path,
      record.candidate,
      record.base_mode,
      function(workspace_err)
        if workspace_err then
          callback(workspace_err)
        else
          self:refresh(callback)
        end
      end
    )
  end

  function Review:accept_file(relative, callback)
    callback = once(callback)
    local record = self._by_path[relative]
    if not record then
      callback({ code = "not_found", message = "unknown review path: " .. relative })
      return
    end
    if record.file_level then
      self:_accept_whole_file(record, callback)
      return
    end
    local function advance(err)
      if err then
        callback(err)
        return
      end
      local current = self._by_path[relative]
      if not current then
        callback()
        return
      end
      for _, hunk in ipairs(current.hunks) do
        if hunk.status == "pending" then
          self:accept_hunk(relative, hunk.id, advance)
          return
        end
      end
      if current.mode_changed then
        self:_accept_mode(current, advance)
        return
      end
      callback()
    end
    advance()
  end

  function Review:_reject_whole_file(record, callback)
    write_shadow(
      self.workspace_root,
      record.path,
      record.base_exists and record.base or nil,
      record.base_mode or record.candidate_mode or 420,
      function(err)
        if err then
          callback(err)
        else
          self:refresh(callback)
        end
      end
    )
  end

  function Review:reject_file(relative, callback)
    callback = once(callback)
    local record = self._by_path[relative]
    if not record then
      callback({ code = "not_found", message = "unknown review path: " .. relative })
      return
    end
    if record.file_level then
      self:_reject_whole_file(record, callback)
      return
    end
    local function advance(err)
      if err then
        callback(err)
        return
      end
      local current = self._by_path[relative]
      if not current then
        callback()
        return
      end
      for _, hunk in ipairs(current.hunks) do
        if hunk.status == "pending" then
          self:reject_hunk(relative, hunk.id, advance)
          return
        end
      end
      if current.mode_changed then
        self:_reject_mode(current, advance)
        return
      end
      callback()
    end
    advance()
  end

  function Review:_sync_record(record, live_bytes, live_exists, live_mode)
    if record.file_level then
      if (live_bytes or "") ~= record.base or live_exists ~= record.base_exists
        or live_mode ~= record.base_mode then
        return nil, true
      end
      return nil
    end
    if record.mode_changed and live_mode ~= record.base_mode then return nil, true end

    local accepted = {}
    local accepted_exists = record.base_exists
    for _, hunk in ipairs(record.hunks) do
      if hunk.status == "accepted" then
        accepted[#accepted + 1] = hunk
        if hunk.file_creation then accepted_exists = true end
      end
    end
    local baseline_count = #diff.lines(record.base).lines
    local accepted_bytes = apply_hunks(record.base, accepted, function(hunk)
      return hunk.base_start, hunk.base_count, hunk.candidate_lines
    end, baseline_count)
    local outstanding = diff.hunks(accepted_bytes, record.candidate)
    if outstanding.binary then return nil, true end
    local user_hunks = diff.hunks(accepted_bytes, live_bytes or "")
    if user_hunks.binary then return nil, true end
    for _, user_hunk in ipairs(user_hunks) do
      for _, proposal in ipairs(outstanding) do
        if overlaps(user_hunk, proposal) then return nil, true end
      end
    end
    if live_exists ~= accepted_exists and #outstanding > 0 then return nil, true end

    local workspace_coordinates = {}
    for _, user_hunk in ipairs(user_hunks) do
      workspace_coordinates[user_hunk] = {
        proposal_start(user_hunk, outstanding),
        user_hunk.base_count,
        user_hunk.candidate_lines,
      }
    end
    local new_workspace = apply_hunks(record.candidate, user_hunks, function(hunk)
      return unpack(workspace_coordinates[hunk])
    end, #diff.lines(accepted_bytes).lines)
    local workspace_exists = record.candidate_exists
    if live_exists ~= accepted_exists and #outstanding == 0 then workspace_exists = live_exists end
    return {
      base = live_exists and (live_bytes or "") or nil,
      workspace = workspace_exists and new_workspace or nil,
      base_mode = record.mode_changed and record.base_mode
        or live_mode or record.base_mode or record.candidate_mode or 420,
      workspace_mode = record.mode_changed and record.candidate_mode
        or live_mode or record.candidate_mode or record.base_mode or 420,
    }
  end

  function Review:sync_live(callback)
    callback = once(callback)
    manifest.scan(self.live.root, {}, function(scan_err, live_entries)
      if scan_err then
        callback(scan_err)
        return
      end
      local paths = {}
      for relative in pairs(self._baseline_entries) do paths[relative] = true end
      for relative in pairs(live_entries) do paths[relative] = true end
      for relative in pairs(self._by_path) do paths[relative] = true end
      if self.live.loaded_paths then
        for _, relative in ipairs(self.live:loaded_paths()) do paths[relative] = true end
      end
      local operations = {}
      local conflicts = {}
      for _, relative in ipairs(sorted_keys(paths)) do
        local base_entry = self._baseline_entries[relative]
        local live_snapshot, snapshot_err = self.live:snapshot(relative)
        if not live_snapshot then
          callback(snapshot_err)
          return
        end
        local live_exists = live_snapshot.exists
        local live_bytes = live_exists and live_snapshot.bytes or nil
        local live_mode = live_snapshot.mode
        local record = self._by_path[relative]
        if record then
          local synced, conflict = self:_sync_record(record, live_bytes, live_exists, live_mode)
          if conflict then
            conflicts[#conflicts + 1] = relative
          elseif synced and ((live_bytes or "") ~= record.base
            or live_exists ~= record.base_exists or live_mode ~= record.base_mode) then
            operations[#operations + 1] = shadow_operation(
              self.baseline_root, relative, synced.base ~= nil, synced.base, synced.base_mode,
              record.base_exists, record.base, record.base_mode or 420
            )
            operations[#operations + 1] = shadow_operation(
              self.workspace_root, relative, synced.workspace ~= nil,
              synced.workspace, synced.workspace_mode,
              record.candidate_exists, record.candidate, record.candidate_mode or 420
            )
          end
        else
          local read_ok, base_bytes = pcall(verified_read, self.baseline_root, relative, base_entry)
          if not read_ok then callback(error_value(base_bytes)); return end
          local base_mode = entry_mode(base_entry)
          local workspace_entry = self._workspace_entries[relative]
          local workspace_ok, workspace_bytes = pcall(
            verified_read, self.workspace_root, relative, workspace_entry
          )
          if not workspace_ok then callback(error_value(workspace_bytes)); return end
          local workspace_mode = entry_mode(workspace_entry)
          if base_bytes ~= live_bytes or (base_entry ~= nil) ~= live_exists
            or (live_exists and base_mode ~= live_mode) then
            operations[#operations + 1] = shadow_operation(
              self.baseline_root, relative, live_exists, live_bytes, live_mode or 420,
              base_entry ~= nil, base_bytes, base_mode or 420
            )
            operations[#operations + 1] = shadow_operation(
              self.workspace_root, relative, live_exists, live_bytes, live_mode or 420,
              workspace_entry ~= nil, workspace_bytes, workspace_mode or 420
            )
          end
        end
      end
      run_transaction(operations, function(operation_err)
        if operation_err then
          refresh_after_failure(self, operation_err, callback)
          return
        end
        local conflicted = {}
        for _, relative in ipairs(conflicts) do conflicted[relative] = true end
        for relative, record in pairs(self._by_path) do
          if not conflicted[relative] then
            for _, hunk in ipairs(record.hunks) do
              if hunk.status == "conflict" then hunk.status = "pending" end
            end
            if record.mode_status == "conflict" then record.mode_status = "pending" end
            if record.file_level and record.status == "conflict" then record.status = "pending" end
            record.status = file_status(record)
          end
        end
        self:refresh(function(refresh_err)
          if refresh_err then
            callback(refresh_err)
            return
          end
          if #conflicts > 0 then
            for _, relative in ipairs(conflicts) do
              local record = self._by_path[relative]
              if record then
                record.status = "conflict"
                for _, hunk in ipairs(record.hunks) do
                  if hunk.status == "pending" then
                    hunk.status = "conflict"
                  end
                end
              end
            end
            callback({ code = "conflict", paths = conflicts, message = "live edits overlap proposals" })
          else
            callback()
          end
        end)
      end)
    end)
  end

  return Review
end

local Review = new()
Review._new = new
return Review
