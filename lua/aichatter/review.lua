local default_diff = require("aichatter.diff")
local default_fs = require("aichatter.fs")
local default_manifest = require("aichatter.manifest")

local function once(callback)
  callback = callback or function() end
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

local function read_file(root, relative)
  local file, err = io.open(root .. "/" .. relative, "rb")
  if not file then
    return nil, err
  end
  local bytes = file:read("*a")
  file:close()
  return bytes
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

  local function run_operations(operations, callback)
    callback = once(callback)
    local index = 1
    local advance
    advance = function(err)
      if err then
        callback(err)
        return
      end
      local operation = operations[index]
      index = index + 1
      if not operation then
        callback()
        return
      end
      local ok, thrown = pcall(operation, advance)
      if not ok then
        callback(error_value(thrown))
      end
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
      local base = before and before.kind == "file" and read_file(self.baseline_root, relative) or nil
      local candidate = after and after.kind == "file" and read_file(self.workspace_root, relative) or nil
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
    local function completed(err)
      if err then
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

  local function apply_hunks(bytes, hunks, coordinate, baseline_count)
    local parsed = diff.lines(bytes)
    local endofline = parsed.endofline
    local ordered = {}
    for _, hunk in ipairs(hunks) do
      ordered[#ordered + 1] = hunk
    end
    table.sort(ordered, function(left, right)
      return coordinate(left) > coordinate(right)
    end)
    baseline_count = baseline_count or #parsed.lines
    for _, hunk in ipairs(ordered) do
      local start, count, replacement = coordinate(hunk)
      parsed.lines = replace_lines(parsed.lines, start, count, replacement)
      if hunk.base_start + hunk.base_count == baseline_count
        and hunk.base_endofline ~= hunk.candidate_endofline then
        endofline = hunk.candidate_endofline
      end
    end
    return lines_bytes(parsed.lines, endofline)
  end

  function Review:_reconcile_after_accept(record, live_hunks, callback)
    local safe = {}
    local workspace_coordinates = {}
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

    local live_mode = self.live:mode(record.path) or record.base_mode or record.candidate_mode or 420
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
    local baseline_count = #diff.lines(record.base).lines
    local new_base = apply_hunks(record.base, safe, function(hunk)
      return hunk.base_start, hunk.base_count, hunk.candidate_lines
    end, baseline_count)
    local new_workspace = apply_hunks(record.candidate, safe, function(hunk)
      return unpack(workspace_coordinates[hunk])
    end, baseline_count)
    run_operations({
      function(done)
        local mode = record.mode_changed and record.base_mode or live_mode
        write_shadow(self.baseline_root, record.path, new_base, mode, done)
      end,
      function(done)
        local mode = record.mode_changed and record.candidate_mode or live_mode
        write_shadow(self.workspace_root, record.path, new_workspace, mode, done)
      end,
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
    elseif hunk.status == "conflict" then
      callback({ code = "conflict", message = "hunk is conflicted" })
      return
    end
    local live_bytes, read_err = self.live:read(relative)
    if read_err then
      callback(read_err)
      return
    end
    local analysis, conflict_err = applies_at_baseline(record, hunk, live_bytes, live_bytes ~= nil)
    if not analysis then
      mark_conflict(record, hunk)
      callback(conflict_err)
      return
    end
    local accepted_bytes = apply_live_hunk(record, hunk, analysis)
    local live_mode = self.live:mode(relative) or record.candidate_mode or record.base_mode or 420
    self.live:write(relative, accepted_bytes, live_mode, function(write_err)
      if write_err then
        callback(write_err)
        return
      end
      hunk.status = "accepted"
      record.status = file_status(record)
      self:_reconcile_after_accept(record, analysis.hunks, function(reconcile_err)
        if reconcile_err then
          callback(reconcile_err)
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

  function Review:_file_conflict(record)
    local live_bytes, read_err = self.live:read(record.path)
    if read_err then
      return read_err
    end
    if (live_bytes ~= nil) ~= record.base_exists or (live_bytes or "") ~= record.base then
      return { code = "conflict", message = "live file changed" }
    end
    local live_mode, mode_err = self.live:mode(record.path)
    if mode_err then
      return mode_err
    end
    if record.base_exists and live_mode ~= record.base_mode then
      return { code = "conflict", message = "live file mode changed" }
    end
  end

  function Review:_accept_whole_file(record, callback)
    local conflict_err = self:_file_conflict(record)
    if conflict_err then
      mark_conflict(record)
      callback(conflict_err)
      return
    end
    local function advance_baseline(live_err)
      if live_err then
        callback(live_err)
        return
      end
      write_shadow(
        self.baseline_root,
        record.path,
        record.candidate_exists and record.candidate or nil,
        record.candidate_mode or record.base_mode or 420,
        function(baseline_err)
          if baseline_err then
            callback(baseline_err)
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
        advance_baseline
      )
    else
      self.live:delete(record.path, advance_baseline)
    end
  end

  function Review:_accept_mode(record, callback)
    callback = once(callback)
    local live_bytes, read_err = self.live:read(record.path)
    if read_err then
      callback(read_err)
      return
    end
    local live_mode, mode_err = self.live:mode(record.path)
    if mode_err then
      callback(mode_err)
      return
    end
    if live_bytes == nil or live_mode ~= record.base_mode then
      record.mode_status = "conflict"
      record.status = "conflict"
      callback({ code = "conflict", message = "live file mode changed" })
      return
    end
    self.live:write(record.path, live_bytes, record.candidate_mode, function(live_err)
      if live_err then
        callback(live_err)
        return
      end
      write_shadow(
        self.baseline_root,
        record.path,
        record.base,
        record.candidate_mode,
        function(baseline_err)
          if baseline_err then
            callback(baseline_err)
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
    local pending = {}
    for _, hunk in ipairs(record.hunks) do
      if hunk.status == "pending" or hunk.status == "conflict" then
        pending[#pending + 1] = hunk
      end
    end
    if record.file_level and ((live_bytes or "") ~= record.base
      or live_exists ~= record.base_exists or live_mode ~= record.base_mode) then
      return nil, true
    end
    if record.mode_changed and live_mode ~= record.base_mode then
      return nil, true
    end
    local live_hunks = diff.hunks(record.base, live_bytes or "")
    if live_hunks.binary then
      return nil, #pending > 0
    end
    for _, live_hunk in ipairs(live_hunks) do
      for _, proposal in ipairs(pending) do
        if overlaps(live_hunk, proposal) then
          return nil, true
        end
      end
    end
    if live_exists ~= record.base_exists and #live_hunks == 0 and #pending > 0 then
      return nil, true
    end

    local workspace_coordinates = {}
    for _, live_hunk in ipairs(live_hunks) do
      local matched
      for _, proposal in ipairs(record.hunks) do
        if overlaps(live_hunk, proposal)
          and live_hunk.base_start == proposal.base_start
          and live_hunk.base_count == proposal.base_count then
          matched = proposal
          break
        end
      end
      if matched then
        workspace_coordinates[live_hunk] = {
          matched.candidate_start,
          matched.candidate_count,
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
    local baseline_count = #diff.lines(record.base).lines
    local new_base = apply_hunks(record.base, live_hunks, function(hunk)
      return hunk.base_start, hunk.base_count, hunk.candidate_lines
    end, baseline_count)
    local new_workspace = apply_hunks(record.candidate, live_hunks, function(hunk)
      return unpack(workspace_coordinates[hunk])
    end, baseline_count)
    return {
      base = live_exists and new_base or nil,
      workspace = live_exists and new_workspace or nil,
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
        local live_bytes, read_err = self.live:read(relative)
        if read_err then
          callback(read_err)
          return
        end
        local live_exists = live_bytes ~= nil
        local live_mode, mode_err = self.live:mode(relative)
        if mode_err then
          callback(mode_err)
          return
        end
        local record = self._by_path[relative]
        if record then
          local synced, conflict = self:_sync_record(record, live_bytes, live_exists, live_mode)
          if conflict then
            conflicts[#conflicts + 1] = relative
          elseif synced and ((live_bytes or "") ~= record.base
            or live_exists ~= record.base_exists or live_mode ~= record.base_mode) then
            operations[#operations + 1] = function(done)
              write_shadow(self.baseline_root, relative, synced.base, synced.base_mode, done)
            end
            operations[#operations + 1] = function(done)
              write_shadow(
                self.workspace_root,
                relative,
                synced.workspace,
                synced.workspace_mode,
                done
              )
            end
          end
        else
          local base_bytes = base_entry and base_entry.kind == "file"
            and read_file(self.baseline_root, relative) or nil
          local base_mode = entry_mode(base_entry)
          if base_bytes ~= live_bytes or (base_entry ~= nil) ~= live_exists
            or (live_exists and base_mode ~= live_mode) then
            operations[#operations + 1] = function(done)
              write_shadow(self.baseline_root, relative, live_bytes, live_mode or 420, done)
            end
            operations[#operations + 1] = function(done)
              write_shadow(self.workspace_root, relative, live_bytes, live_mode or 420, done)
            end
          end
        end
      end
      run_operations(operations, function(operation_err)
        if operation_err then
          callback(operation_err)
          return
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
