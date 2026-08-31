# aichatter.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Lua Neovim sidebar that runs complete Codex turns in an isolated shadow workspace and exposes per-file, per-hunk review before any live edit is applied.

**Architecture:** A single session owns a stdio JSON-RPC connection to `codex app-server`, a protected baseline snapshot, and a writable shadow workspace. Focused Lua modules handle transport, authentication, shadow synchronization, diff/review state, and buffer UI; the real project is updated only by conflict-checked review actions.

**Tech Stack:** LuaJIT, Neovim 0.10+ APIs (`vim.system`, `vim.uv`, `vim.diff`, buffers, extmarks), Codex app-server v2, Git for Git projects, headless Neovim tests with an in-repo test harness.

**Spec:** `docs/superpowers/specs/2026-08-31-aichatter-nvim-design.md`

## Global Constraints

- Support Neovim 0.10 or newer on Linux and macOS; native Windows support is out of scope for v1.
- Runtime dependencies are Neovim, a Codex CLI whose app-server supports ephemeral roots and restricted read access, and Git only for Git projects; do not add Node.js, Python, or a compiled helper.
- Keep one ephemeral chat session per Neovim process and do not implement a history picker.
- Keep live files and buffers byte-for-byte unchanged until the user accepts a hunk or whole binary-file proposal.
- Overlay unsaved buffer content into the shadow workspace and never save a user's buffer automatically.
- Let each Codex turn finish before exposing file review; only risky command approvals may interrupt a turn.
- Install no mandatory global keymaps; use commands, `<Plug>` mappings, and buffer-local defaults.
- Use a temporary local Git clone with `--local --no-hardlinks` for Git projects and a plain mirror for non-Git projects.
- Restrict Codex writes to the shadow workspace and disable network access until explicitly approved.
- Keep modules focused and use dependency injection at filesystem, process, URL-opening, and UI-confirmation boundaries.

---

## Planned File Structure

### Runtime

- `plugin/aichatter.lua` — one-time command registration on plugin load.
- `lua/aichatter/init.lua` — public `setup`, command handlers, and session singleton.
- `lua/aichatter/config.lua` — defaults, validation, and buffer-local mapping configuration.
- `lua/aichatter/jsonl.lua` — chunk-safe newline-delimited JSON framing.
- `lua/aichatter/transport.lua` — app-server process and JSON-RPC lifecycle.
- `lua/aichatter/auth.lua` — account inspection and ChatGPT browser login.
- `lua/aichatter/path.lua` — normalized path joins, containment, and project-root detection.
- `lua/aichatter/fs.lua` — cancellable tree copy, atomic write, and guarded removal.
- `lua/aichatter/shadow.lua` — workspace/baseline creation, buffer overlay, synchronization, and cleanup.
- `lua/aichatter/manifest.lua` — recursive content manifests and change classification.
- `lua/aichatter/diff.lua` — binary detection and exact text hunks.
- `lua/aichatter/live.lua` — safe loaded-buffer and unloaded-file reads/writes.
- `lua/aichatter/review.lua` — proposal state and accept/reject/edit/conflict operations.
- `lua/aichatter/context.lua` — `@file`, current-buffer, and visual-selection inputs.
- `lua/aichatter/session.lua` — product state machine and complete-turn orchestration.
- `lua/aichatter/ui/init.lua` — view composition and UI/session event binding.
- `lua/aichatter/ui/layout.lua` — right sidebar and three-window geometry.
- `lua/aichatter/ui/transcript.lua` — conversation, activity, error, and approval rendering.
- `lua/aichatter/ui/composer.lua` — multiline input and context chips.
- `lua/aichatter/ui/changes.lua` — file queue and file-level actions.
- `lua/aichatter/ui/diff.lua` — unified highlighted hunk review and candidate edit mode.

### Tests and project support

- `Makefile` — `make test` and focused `TEST=...` execution.
- `tests/minimal_init.lua` — isolated runtime path and deterministic options.
- `tests/helpers.lua` — tiny test registry, assertions, temp directories, and async waiting.
- `tests/run.lua` — discovers and executes `*_spec.lua` files.
- `tests/fixtures/fake_app_server.lua` — deterministic stdio JSON-RPC server scenarios.
- `tests/*_spec.lua` — unit and integration coverage matching runtime modules.
- `.github/workflows/ci.yml` — Linux headless test job on the minimum supported Neovim.
- `README.md` — install, Codex prerequisite, login, commands, mappings, workflow, and limitations.
- `doc/aichatter.txt` — `:help aichatter` reference generated from the same public surface.

---

### Task 1: Bootstrap the Lua module and headless test harness

**Files:**
- Create: `Makefile`
- Create: `tests/minimal_init.lua`
- Create: `tests/helpers.lua`
- Create: `tests/run.lua`
- Create: `tests/config_spec.lua`
- Create: `lua/aichatter/config.lua`
- Create: `lua/aichatter/init.lua`

**Interfaces:**
- Consumes: none.
- Produces: `require("aichatter").setup(opts?) -> nil`; `config.setup(opts?) -> table`; `config.get() -> table`; `make test`; `make test TEST=tests/config_spec.lua`; base test helpers `test`, `eq`, `truthy`, `falsy`, `matches`, `raises`, `wait_for`, `tempdir`, `read`, `write`, `mkdir`, `symlink`, and `run`.

- [ ] **Step 1: Create the test harness and failing configuration tests**

```lua
-- tests/config_spec.lua
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
```

Create `tests/helpers.lua` with `test(name, fn)`, `eq(expected, actual)`, `truthy(value)`, `falsy(value)`, `matches(pattern, value)`, `raises(pattern, fn)`, `wait_for(predicate, timeout_ms)`, `tempdir()`, `read(path)`, `write(path, bytes)`, `mkdir(path)`, `symlink(target, path)`, and `run()`. `run()` must execute each registered case with `xpcall`, print one `PASS` or `FAIL` line, remove helper-created temporary directories, and call `vim.cmd("cquit 1")` when any case fails or `vim.cmd("qa!")` when all pass.

Create `tests/run.lua` to execute either `$TEST` or every sorted `tests/*_spec.lua` file, excluding helpers and fixtures. Create `tests/minimal_init.lua` with `vim.opt.runtimepath:prepend(vim.fn.getcwd())`, `vim.opt.swapfile = false`, and `vim.opt.shadafile = "NONE"`.

```make
# Makefile
.PHONY: test
test:
	TEST="$(TEST)" nvim --headless --clean -u tests/minimal_init.lua \
		-c "lua dofile('tests/run.lua')"
```

- [ ] **Step 2: Run the focused test and verify the intended failure**

Run: `make test TEST=tests/config_spec.lua`

Expected: FAIL because `lua/aichatter/config.lua` does not exist.

- [ ] **Step 3: Implement configuration and the public setup entry point**

```lua
-- lua/aichatter/config.lua
local M = {}
local current

local defaults = {
  side = "right",
  width = 0.35,
  composer_height = 0.20,
  codex_cmd = { "codex", "app-server", "--listen", "stdio://" },
  mappings = {
    submit = "<CR>", newline = "<C-j>", open = "o",
    accept = "a", reject = "r", edit = "e",
    previous_hunk = "[c", next_hunk = "]c",
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
```

```lua
-- lua/aichatter/init.lua
local M = {}

function M.setup(opts)
  require("aichatter.config").setup(opts)
end

return M
```

- [ ] **Step 4: Run all bootstrap tests**

Run: `make test`

Expected: two PASS lines and exit code 0.

- [ ] **Step 5: Commit the bootstrap**

```bash
git add Makefile tests lua/aichatter/config.lua lua/aichatter/init.lua
git commit -m "test: bootstrap aichatter lua project"
```

---

### Task 2: Implement JSONL framing and app-server transport

**Files:**
- Create: `lua/aichatter/jsonl.lua`
- Create: `lua/aichatter/transport.lua`
- Create: `tests/jsonl_spec.lua`
- Create: `tests/transport_spec.lua`
- Create: `tests/fixtures/fake_app_server.lua`

**Interfaces:**
- Consumes: `config.codex_cmd`; `helpers.wait_for`.
- Produces: `jsonl.new(on_value, on_error)` with `:push(chunk)` and `:finish()`; `Transport.new(opts)` with `:start(cb)`, `:request(method, params, cb)`, `:notify(method, params)`, `:respond(id, result, err)`, `:on(method, fn)`, `:off(method, fn)`, and `:stop(cb)`.

- [ ] **Step 1: Write failing framer and transport tests**

```lua
-- tests/jsonl_spec.lua
local h = require("tests.helpers")
local jsonl = require("aichatter.jsonl")

h.test("frames partial and multiple JSON lines", function()
  local values = {}
  local parser = jsonl.new(function(value) values[#values + 1] = value end)
  parser:push('{"id":1}\n{"method":"turn/')
  parser:push('completed"}\n')
  h.eq(2, #values)
  h.eq(1, values[1].id)
  h.eq("turn/completed", values[2].method)
end)

h.test("reports malformed JSON without dropping the following line", function()
  local values, errors = {}, {}
  local parser = jsonl.new(
    function(value) values[#values + 1] = value end,
    function(err) errors[#errors + 1] = err end
  )
  parser:push('not-json\n{"id":2}\n')
  h.eq(1, #errors)
  h.eq(2, values[1].id)
end)
```

```lua
-- tests/transport_spec.lua
local h = require("tests.helpers")
local Transport = require("aichatter.transport")

h.test("initializes and correlates a response from a real child process", function()
  local transport = Transport.new({
    cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l",
      "tests/fixtures/fake_app_server.lua", "initialize" },
  })
  local result
  transport:start(function(err)
    h.eq(nil, err)
    transport:request("account/read", { refreshToken = false }, function(req_err, value)
      h.eq(nil, req_err)
      result = value
    end)
  end)
  h.truthy(h.wait_for(function() return result ~= nil end, 2000))
  h.eq("chatgpt", result.account.type)
  transport:stop()
end)
```

The fixture must parse stdin one line at a time, respond to `initialize` and `account/read`, ignore `initialized`, flush stdout after each JSON line, and write diagnostics only to stderr.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `make test TEST=tests/jsonl_spec.lua`

Expected: FAIL because `aichatter.jsonl` does not exist.

Run: `make test TEST=tests/transport_spec.lua`

Expected: FAIL because `aichatter.transport` does not exist.

- [ ] **Step 3: Implement the JSONL parser**

```lua
-- lua/aichatter/jsonl.lua
local M = {}

function M.new(on_value, on_error)
  local self = { buffer = "" }
  function self:push(chunk)
    self.buffer = self.buffer .. (chunk or "")
    while true do
      local newline = self.buffer:find("\n", 1, true)
      if not newline then return end
      local line = self.buffer:sub(1, newline - 1)
      self.buffer = self.buffer:sub(newline + 1)
      if line ~= "" then
        local ok, value = pcall(vim.json.decode, line)
        if ok then on_value(value) elseif on_error then on_error(value, line) end
      end
    end
  end
  function self:finish()
    if self.buffer ~= "" and on_error then
      on_error("unterminated JSONL frame", self.buffer)
    end
    self.buffer = ""
  end
  return self
end

return M
```

- [ ] **Step 4: Implement process and JSON-RPC lifecycle**

`transport.lua` must keep `next_id`, `pending`, and per-method listener arrays. Start `vim.system(opts.cmd, { stdin = true, text = true, stdout = on_stdout, stderr = on_stderr }, on_exit)`. The stdout callback feeds `jsonl`; all callbacks entering Neovim state must run through `vim.schedule`.

```lua
function Transport:request(method, params, callback)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = callback
  self:_write({ id = id, method = method, params = params })
  return id
end

function Transport:_dispatch(message)
  if message.id and not message.method then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    if callback then callback(message.error, message.result) end
    return
  end
  if message.id and message.method then
    self:_emit(message.method, message.params, message.id)
    return
  end
  if message.method then self:_emit(message.method, message.params) end
end
```

`start` must wait for the process handle, send `initialize` with `clientInfo = { name = "aichatter.nvim", version = "0.1.0" }`, then send `initialized` only after a successful response. `stop` must reject every pending request with `{ message = "transport stopped" }`, close stdin, and terminate the process if it remains alive.

- [ ] **Step 5: Run framing and child-process tests**

Run: `make test TEST=tests/jsonl_spec.lua`

Expected: PASS.

Run: `make test TEST=tests/transport_spec.lua`

Expected: PASS with the fake process exiting cleanly.

- [ ] **Step 6: Commit transport support**

```bash
git add lua/aichatter/jsonl.lua lua/aichatter/transport.lua tests/jsonl_spec.lua tests/transport_spec.lua tests/fixtures/fake_app_server.lua
git commit -m "feat: add codex app-server transport"
```

---

### Task 3: Add account detection and ChatGPT browser login

**Files:**
- Create: `lua/aichatter/auth.lua`
- Create: `tests/auth_spec.lua`
- Modify: `lua/aichatter/transport.lua`
- Modify: `tests/transport_spec.lua`

**Interfaces:**
- Consumes: `Transport:request`, `Transport:on`, and `Transport:off`.
- Produces: `Auth.new(transport, opts)`; `Auth:check(cb)` returning `{ authenticated, account, requires_openai_auth }`; `Auth:login(cb)` returning the login result after the completion notification; `opts.open_url(url)` defaults to `vim.ui.open`.

- [ ] **Step 1: Write failing authentication tests with a transport double**

```lua
local h = require("tests.helpers")
local Auth = require("aichatter.auth")

h.test("reuses an existing ChatGPT account", function()
  local transport = h.fake_transport({
    ["account/read"] = { account = { type = "chatgpt" }, requiresOpenaiAuth = true },
  })
  local state
  Auth.new(transport):check(function(err, value)
    h.eq(nil, err)
    state = value
  end)
  h.truthy(state.authenticated)
end)

h.test("opens the managed login URL and waits for completion", function()
  local opened, completed
  local transport = h.fake_transport({
    ["account/login/start"] = {
      type = "chatgpt", loginId = "login-1", authUrl = "https://chatgpt.com/auth",
    },
  })
  local auth = Auth.new(transport, { open_url = function(url) opened = url end })
  auth:login(function(err, value) h.eq(nil, err); completed = value end)
  h.eq("https://chatgpt.com/auth", opened)
  transport:emit("account/login/completed", { loginId = "login-1", success = true })
  h.truthy(completed.success)
end)
```

Add `helpers.fake_transport(responses)` with deterministic `request`, `on`, `off`, `emit`, and `responded` recording; this helper is reused by later session tests.

- [ ] **Step 2: Verify the tests fail for the missing auth module**

Run: `make test TEST=tests/auth_spec.lua`

Expected: FAIL because `aichatter.auth` does not exist.

- [ ] **Step 3: Implement account and login flows**

```lua
function Auth:check(callback)
  self.transport:request("account/read", { refreshToken = false }, function(err, result)
    if err then return callback(err) end
    callback(nil, {
      authenticated = result.account ~= nil,
      account = result.account,
      requires_openai_auth = result.requiresOpenaiAuth,
    })
  end)
end

function Auth:login(callback)
  self.transport:request("account/login/start", {
    type = "chatgpt", useHostedLoginSuccessPage = true, appBrand = "codex",
  }, function(err, result)
    if err then return callback(err) end
    local listener
    listener = function(params)
      if params.loginId ~= result.loginId then return end
      self.transport:off("account/login/completed", listener)
      callback(params.success and nil or { message = params.error }, params)
    end
    self.transport:on("account/login/completed", listener)
    self.open_url(result.authUrl)
  end)
end
```

Guard against a second concurrent login and clear the listener on cancellation or transport exit.

- [ ] **Step 4: Add listener-removal coverage and run tests**

Add a test that emits completion twice and asserts the login callback runs once. Run: `make test TEST=tests/auth_spec.lua`

Expected: all auth cases PASS.

- [ ] **Step 5: Commit authentication**

```bash
git add lua/aichatter/auth.lua lua/aichatter/transport.lua tests/auth_spec.lua tests/transport_spec.lua tests/helpers.lua
git commit -m "feat: add codex chatgpt login"
```

---

### Task 4: Implement safe filesystem and path primitives

**Files:**
- Create: `lua/aichatter/path.lua`
- Create: `lua/aichatter/fs.lua`
- Create: `tests/path_spec.lua`
- Create: `tests/fs_spec.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: `vim.uv`; test temporary directories.
- Produces: `path.normalize`, `path.join`, `path.relative`, `path.is_within`, `path.project_root`; `fs.copy_tree(source, target, opts, cb)`; `fs.atomic_write(path, bytes, mode, cb)`; `fs.remove_tree_guarded(target, expected_parent, cb)`.

- [ ] **Step 1: Write failing containment, copy, cancellation, and removal tests**

```lua
h.test("rejects sibling paths that share a string prefix", function()
  h.truthy(path.is_within("/tmp/project", "/tmp/project/file.lua"))
  h.falsy(path.is_within("/tmp/project", "/tmp/project-old/file.lua"))
end)

h.test("copies files and internal symlinks while excluding .git", function()
  local source, target = h.tempdir(), h.tempdir() .. "/copy"
  h.write(source .. "/a.lua", "return 1\n")
  h.mkdir(source .. "/.git")
  h.write(source .. "/.git/config", "secret")
  h.symlink("a.lua", source .. "/linked.lua")
  local done
  fs.copy_tree(source, target, { exclude = { [".git"] = true } }, function(err)
    h.eq(nil, err); done = true
  end)
  h.truthy(h.wait_for(function() return done end, 2000))
  h.eq("return 1\n", h.read(target .. "/a.lua"))
  h.eq("a.lua", vim.uv.fs_readlink(target .. "/linked.lua"))
  h.eq(nil, vim.uv.fs_stat(target .. "/.git"))
end)

h.test("refuses cleanup outside the recorded temp parent", function()
  local err
  fs.remove_tree_guarded("/tmp/not-the-session", "/tmp/aichatter-session", function(value)
    err = value
  end)
  h.matches("outside expected parent", err.message)
end)
```

- [ ] **Step 2: Run focused tests and verify missing-module failures**

Run: `make test TEST=tests/path_spec.lua`

Expected: FAIL because `aichatter.path` does not exist.

Run: `make test TEST=tests/fs_spec.lua`

Expected: FAIL because `aichatter.fs` does not exist.

- [ ] **Step 3: Implement normalized path and project-root functions**

Use `vim.fs.normalize`, resolve relative inputs against an explicit base, and compare path components rather than prefixes. `project_root(start)` must return the output directory of `git -C <start> rev-parse --show-toplevel` when successful and normalized `start` otherwise.

```lua
function M.is_within(parent, child)
  parent, child = M.normalize(parent), M.normalize(child)
  if parent == child then return true end
  local prefix = parent:sub(-1) == "/" and parent or parent .. "/"
  return child:sub(1, #prefix) == prefix
end
```

- [ ] **Step 4: Implement cancellable tree copy, atomic write, and guarded removal**

`copy_tree` must use `vim.uv.fs_lstat` so it never follows symlinks. Recreate directories, byte-copy regular files while preserving executable mode, and recreate symlinks with their original link text. Process at most 128 entries before scheduling the next batch, call `opts.on_progress(copied_count, relative_path)`, and stop with `{ code = "cancelled" }` when `opts.cancel.cancelled` becomes true.

```lua
local function copy_entry(job, source, target, relative)
  local stat = assert(uv.fs_lstat(source))
  if stat.type == "directory" then
    assert(uv.fs_mkdir(target, stat.mode))
    enqueue_children(job, source, target, relative)
  elseif stat.type == "link" then
    assert(uv.fs_symlink(assert(uv.fs_readlink(source)), target))
  elseif stat.type == "file" then
    copy_file_bytes(source, target, stat.mode)
  end
end
```

`atomic_write` writes to a uniquely named sibling, `fsync`s and closes it, applies the requested mode, then renames it over the destination. `remove_tree_guarded` normalizes both inputs, requires strict containment and a basename beginning `aichatter-`, recursively unlinks without following symlinks, and removes directories bottom-up.

- [ ] **Step 5: Run path and filesystem tests**

Run: `make test TEST=tests/path_spec.lua`

Expected: PASS.

Run: `make test TEST=tests/fs_spec.lua`

Expected: copy, cancellation, symlink, atomic-write, and cleanup cases PASS.

- [ ] **Step 6: Commit filesystem primitives**

```bash
git add lua/aichatter/path.lua lua/aichatter/fs.lua tests/path_spec.lua tests/fs_spec.lua tests/helpers.lua
git commit -m "feat: add safe shadow filesystem primitives"
```

---

### Task 5: Build the protected baseline and shadow workspace

**Files:**
- Create: `lua/aichatter/shadow.lua`
- Create: `tests/shadow_spec.lua`
- Modify: `lua/aichatter/fs.lua`
- Modify: `tests/fs_spec.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: `path.project_root`; `fs.copy_tree`; injected `run(argv, cb)` and `buffer_provider(root)`.
- Produces: `Shadow.create(opts, cb) -> Shadow`; fields `session_root`, `baseline_root`, `workspace_root`, `project_root`; methods `:sync_live(exclude_paths, cb)`, `:overlay_buffers(cb)`, and `:cleanup(cb)`.

- [ ] **Step 1: Write failing non-Git and Git shadow tests**

```lua
h.test("creates separate baseline and workspace with unsaved buffer content", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "return 1\n")
  local shadow
  Shadow.create({
    root = root,
    temp_parent = h.tempdir(),
    buffer_provider = function()
      return { { path = root .. "/main.lua", bytes = "return 2\n", mode = 420 } }
    end,
  }, function(err, value) h.eq(nil, err); shadow = value end)
  h.truthy(h.wait_for(function() return shadow ~= nil end, 3000))
  h.eq("return 2\n", h.read(shadow.baseline_root .. "/main.lua"))
  h.eq("return 2\n", h.read(shadow.workspace_root .. "/main.lua"))
  h.eq("return 1\n", h.read(root .. "/main.lua"))
end)

h.test("uses an independent local clone for a Git project", function()
  local root = h.git_project({ ["tracked.txt"] = "base\n" })
  h.write(root .. "/tracked.txt", "dirty\n")
  h.write(root .. "/ignored.bin", "dependency\n")
  local shadow = h.create_shadow(root)
  h.eq("dirty\n", h.read(shadow.workspace_root .. "/tracked.txt"))
  h.eq("dependency\n", h.read(shadow.workspace_root .. "/ignored.bin"))
  h.falsy(path.is_within(root .. "/.git", shadow.workspace_root .. "/.git"))
end)
```

Extend `tests/helpers.lua` with `git_project(files)` and `create_shadow(root)`. `git_project` initializes a temporary repository, configures local test-only author values, writes the supplied files, and commits them. `create_shadow` waits for the asynchronous callback and fails the test on timeout.

```lua
function M.create_shadow(root)
  local value, failure
  Shadow.create({ root = root, temp_parent = M.tempdir() }, function(err, result)
    failure, value = err, result
  end)
  assert(M.wait_for(function() return failure ~= nil or value ~= nil end, 3000))
  assert(not failure, vim.inspect(failure))
  return value
end
```

- [ ] **Step 2: Verify shadow tests fail**

Run: `make test TEST=tests/shadow_spec.lua`

Expected: FAIL because `aichatter.shadow` does not exist.

- [ ] **Step 3: Implement session directory and Git/non-Git workspace creation**

Create `<temp_parent>/aichatter-<random>/control/baseline` and `<temp_parent>/aichatter-<random>/workspace`. For Git roots, execute `git clone --local --no-hardlinks -- <root> <workspace>`, then overlay the live tree with `.git` excluded. For non-Git roots, copy the live tree directly to `workspace`. In both cases, copy the resulting workspace to `control/baseline` with `.git` excluded so Codex cannot access or mutate baseline bytes.

```lua
local function clone_args(root, workspace)
  return { "git", "clone", "--local", "--no-hardlinks", "--", root, workspace }
end
```

Detect Git with `git -C <root> rev-parse --is-inside-work-tree`. Preserve a structured error containing the failed argv, exit code, and stderr.

- [ ] **Step 4: Overlay loaded buffers without saving them**

The default `buffer_provider` must enumerate loaded, named buffers under the project root, read their lines with `nvim_buf_get_lines`, preserve final-newline state from `vim.bo[buf].endofline`, and return mode from the existing file or `0644`. Apply each result to both baseline and workspace using `fs.atomic_write`.

```lua
local function buffer_bytes(bufnr)
  local bytes = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if vim.bo[bufnr].endofline then bytes = bytes .. "\n" end
  return bytes
end
```

- [ ] **Step 5: Implement synchronization and cleanup**

`sync_live` recopies paths without proposals, while callers pass an exclusion set for proposed files. It updates baseline and workspace together. `cleanup` stops outstanding copy work, then calls `remove_tree_guarded(session_root, temp_parent)` exactly once.

- [ ] **Step 6: Run shadow tests and assert source immutability**

Run: `make test TEST=tests/shadow_spec.lua`

Expected: Git, non-Git, unsaved overlay, cancellation, and cleanup cases PASS; source bytes remain unchanged.

- [ ] **Step 7: Commit shadow creation**

```bash
git add lua/aichatter/shadow.lua lua/aichatter/fs.lua tests/shadow_spec.lua tests/fs_spec.lua tests/helpers.lua
git commit -m "feat: isolate codex work in a shadow workspace"
```

---

### Task 6: Detect file changes and compute exact review hunks

**Files:**
- Create: `lua/aichatter/manifest.lua`
- Create: `lua/aichatter/diff.lua`
- Create: `tests/manifest_spec.lua`
- Create: `tests/diff_spec.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: protected baseline root and writable workspace root.
- Produces: `manifest.scan(root, opts, cb) -> entries`; `manifest.compare(base, candidate) -> change records`; `diff.is_binary(bytes) -> boolean`; `diff.lines(bytes) -> { lines, endofline }`; `diff.hunks(base_bytes, candidate_bytes) -> hunks`.

- [ ] **Step 1: Write failing manifest and hunk tests**

```lua
h.test("classifies modified, created, and deleted paths", function()
  local base, candidate = h.tempdir(), h.tempdir()
  h.write(base .. "/modified.txt", "old\n")
  h.write(candidate .. "/modified.txt", "new\n")
  h.write(base .. "/deleted.txt", "gone\n")
  h.write(candidate .. "/created.txt", "here\n")
  local changes = h.scan_changes(base, candidate)
  h.eq("modified", changes["modified.txt"].kind)
  h.eq("deleted", changes["deleted.txt"].kind)
  h.eq("created", changes["created.txt"].kind)
end)

h.test("returns independent line hunks", function()
  local hunks = diff.hunks("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  h.eq(2, #hunks)
  h.eq({ "b" }, hunks[1].base_lines)
  h.eq({ "B" }, hunks[1].candidate_lines)
  h.eq({ "d" }, hunks[2].base_lines)
  h.eq({ "D" }, hunks[2].candidate_lines)
end)

h.test("marks NUL-containing files as binary", function()
  h.truthy(diff.is_binary("abc\0def"))
end)
```

Add `scan_changes(base, candidate)` to `tests/helpers.lua`; it waits for both `manifest.scan` callbacks, fails on either error, and returns `manifest.compare(base_entries, candidate_entries)`.

```lua
function M.scan_changes(base, candidate)
  local before, after
  manifest.scan(base, {}, function(err, value) assert(not err); before = value end)
  manifest.scan(candidate, {}, function(err, value) assert(not err); after = value end)
  assert(M.wait_for(function() return before and after end, 2000))
  return manifest.compare(before, after)
end
```

- [ ] **Step 2: Run tests and verify missing-module failures**

Run: `make test TEST=tests/manifest_spec.lua`

Expected: FAIL because `aichatter.manifest` does not exist.

Run: `make test TEST=tests/diff_spec.lua`

Expected: FAIL because `aichatter.diff` does not exist.

- [ ] **Step 3: Implement content manifests and classification**

Skip `.git` and never follow symlinks. Each regular-file entry contains `kind = "file"`, `size`, `mode`, `digest = vim.fn.sha256(bytes)`, and `binary`. Symlink entries contain `kind = "link"` and `target`. Compare the union of relative paths in sorted order; equal digests and modes are unchanged.

```lua
function M.compare(base, candidate)
  local result = {}
  for _, relative in ipairs(sorted_union(base, candidate)) do
    local before, after = base[relative], candidate[relative]
    if not before then result[relative] = { path = relative, kind = "created", after = after }
    elseif not after then result[relative] = { path = relative, kind = "deleted", before = before }
    elseif not same_entry(before, after) then
      result[relative] = { path = relative, kind = "modified", before = before, after = after }
    end
  end
  return result
end
```

- [ ] **Step 4: Implement exact text hunks with final-newline metadata**

Split bytes without losing whether the file ends in a newline. Call `vim.diff(base_bytes, candidate_bytes, { result_type = "indices", algorithm = "histogram", ctxlen = 3 })`. Convert each `{ a_start, a_count, b_start, b_count }` result to a stable hunk containing `id`, zero-based application ranges, copied base/candidate lines, and `status = "pending"`.

Created text files receive insertion hunks; deleted text files receive one file-deletion record; binary changes return `{ binary = true }` without text hunks.

- [ ] **Step 5: Run manifest and diff suites**

Run: `make test TEST=tests/manifest_spec.lua`

Expected: all change classifications PASS.

Run: `make test TEST=tests/diff_spec.lua`

Expected: replacement, insertion, deletion, separate-hunk, final-newline, and binary cases PASS.

- [ ] **Step 6: Commit change detection**

```bash
git add lua/aichatter/manifest.lua lua/aichatter/diff.lua tests/manifest_spec.lua tests/diff_spec.lua
git commit -m "feat: compute reviewable file hunks"
```

---

### Task 7: Implement conflict-safe live updates and review state

**Files:**
- Create: `lua/aichatter/live.lua`
- Create: `lua/aichatter/review.lua`
- Create: `tests/live_spec.lua`
- Create: `tests/review_spec.lua`
- Modify: `lua/aichatter/shadow.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: manifest change records; `diff.hunks`; baseline/workspace roots.
- Produces: `Live.new(root)` with synchronous `:read(relative)` plus asynchronous `:write(relative, bytes, mode, cb)` and `:delete(relative, cb)`; `Review.new({ baseline_root, workspace_root, live })` with `:refresh(cb)`, `:sync_live(cb)`, `:files()`, `:accept_hunk(path, id, cb)`, `:reject_hunk(path, id, cb)`, `:edit_candidate(path, bytes, cb)`, `:accept_file(path, cb)`, and `:reject_file(path, cb)`.

- [ ] **Step 1: Write failing live-buffer and review tests**

```lua
h.test("updates a loaded unsaved buffer without writing disk", function()
  local root = h.tempdir()
  h.write(root .. "/main.lua", "disk\n")
  local bufnr = h.load_buffer(root .. "/main.lua", { "unsaved" }, true)
  local live = Live.new(root)
  live:write("main.lua", "accepted\n", 420)
  h.eq({ "accepted" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  h.truthy(vim.bo[bufnr].modified)
  h.eq("disk\n", h.read(root .. "/main.lua"))
end)

h.test("accepts one hunk and rejects another", function()
  local fixture = h.review_fixture("a\nb\nc\nd\n", "a\nB\nc\nD\n")
  fixture.review:accept_hunk("main.txt", 1, h.assert_no_error)
  fixture.review:reject_hunk("main.txt", 2, h.assert_no_error)
  h.eq("a\nB\nc\nd\n", fixture.live_bytes())
  h.eq("a\nB\nc\nd\n", fixture.workspace_bytes())
end)

h.test("marks an overlapping live edit as conflict", function()
  local fixture = h.review_fixture("a\nb\n", "a\nB\n")
  fixture.set_live("a\nuser edit\n")
  local captured
  fixture.review:accept_hunk("main.txt", 1, function(err) captured = err end)
  h.eq("conflict", captured.code)
  h.eq("conflict", fixture.review:files()[1].status)
  h.eq("a\nuser edit\n", fixture.live_bytes())
end)
```

Extend `tests/helpers.lua` with `load_buffer`, `assert_no_error`, and `review_fixture`. The fixture creates separate baseline, workspace, and live roots, writes `main.txt` to all three, constructs `Review.new({ baseline_root, workspace_root, live = Live.new(live_root) })`, calls `refresh`, and returns accessors that read or replace live/workspace bytes.

```lua
function M.assert_no_error(err)
  assert(err == nil, vim.inspect(err))
end

function M.load_buffer(filename, lines, modified)
  local bufnr = vim.fn.bufadd(filename)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = modified
  return bufnr
end
```

- [ ] **Step 2: Run tests and verify failures**

Run: `make test TEST=tests/live_spec.lua`

Expected: FAIL because `aichatter.live` does not exist.

Run: `make test TEST=tests/review_spec.lua`

Expected: FAIL because `aichatter.review` does not exist.

- [ ] **Step 3: Implement loaded-buffer-preserving live access**

Resolve a loaded buffer by normalized filename. `read` returns buffer bytes when loaded and disk bytes otherwise. `write` calls `nvim_buf_set_lines` and adjusts `endofline` for a loaded buffer; it calls `fs.atomic_write` for an unloaded path. `delete` refuses to delete a modified loaded buffer and otherwise deletes the unloaded file or marks a loaded unmodified buffer deleted without saving unrelated state.

```lua
function Live:write(relative, bytes, mode, callback)
  local absolute = path.join(self.root, relative)
  local bufnr = self:_loaded_buffer(absolute)
  if not bufnr then return fs.atomic_write(absolute, bytes, mode, callback) end
  local parsed = diff.lines(bytes)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, parsed.lines)
  vim.bo[bufnr].endofline = parsed.endofline
  callback(nil)
end
```

- [ ] **Step 4: Implement review refresh and hunk decisions**

`refresh` scans baseline and workspace, loads changed bytes, computes hunks, and preserves decisions only when hunk content and ranges still match. `sync_live` compares baseline-to-live hunks with pending baseline-to-workspace hunks, incorporates non-overlapping live edits into baseline and workspace, and returns `{ code = "conflict", paths = {...} }` without starting a turn when ranges overlap. Accept verifies the hunk's baseline slice against current live lines after accounting for accepted offsets; on mismatch it sets `conflict` without writing. On success it applies candidate lines to live, then incorporates any non-overlapping live-only lines into both baseline and workspace before recomputing the diff. Reject applies baseline lines to workspace only and recomputes. `edit_candidate` writes the complete candidate bytes to workspace and recomputes every hunk for the file.

File-level operations iterate only pending hunks. Binary accept copies candidate bytes to live and baseline; binary reject restores workspace from baseline. File deletion uses explicit whole-file confirmation and the same conflict check against baseline bytes.

- [ ] **Step 5: Add non-overlapping concurrent-edit coverage**

Add a test where live line 10 changes while Codex changes line 2. Accepting the Codex hunk must preserve the user line 10 change. Add a second test where both change line 2 and assert zero live writes plus `conflict` status.

Run: `make test TEST=tests/review_spec.lua`

Expected: every accept, reject, edit, binary, deletion, and conflict case PASS.

- [ ] **Step 6: Commit the review engine**

```bash
git add lua/aichatter/live.lua lua/aichatter/review.lua lua/aichatter/shadow.lua tests/live_spec.lua tests/review_spec.lua tests/helpers.lua
git commit -m "feat: add conflict-safe hunk review"
```

---

### Task 8: Orchestrate contexts, ephemeral turns, approvals, and restart

**Files:**
- Create: `lua/aichatter/context.lua`
- Create: `lua/aichatter/session.lua`
- Create: `tests/context_spec.lua`
- Create: `tests/session_spec.lua`
- Modify: `lua/aichatter/transport.lua`
- Modify: `tests/fixtures/fake_app_server.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: Transport, Auth, Shadow, Review, and injected event sink.
- Produces: `Context.new(root)` with `:add_file(path)`, `:add_buffer(bufnr)`, `:add_selection(path, first, last, lines)`, `:inputs(text)`, and `:clear()`; `Session.new(deps)` with `:start(cb)`, `:login(cb)`, `:send(text, cb)`, `:steer(text, cb)`, `:approve_command(request_id, decision)`, `:cancel(cb)`, and `:close(cb)`.

- [ ] **Step 1: Write failing context and state-machine tests**

```lua
h.test("builds prompt inputs from text, file, and visual selection", function()
  local context = Context.new("/project")
  context:add_file("/project/lua/main.lua")
  context:add_selection("/project/lua/main.lua", 5, 8,
    { "local x = 1", "return x" })
  local inputs = context:inputs("Explain this")
  h.eq({ type = "text", text = "Explain this" }, inputs[1])
  h.eq("@lua/main.lua", inputs[2].text)
  h.matches("lines 5%-8", inputs[3].text)
end)

h.test("does not expose review until turn completion", function()
  local fixture = h.session_fixture()
  fixture.session:send("Change main.lua")
  fixture.transport:emit("item/agentMessage/delta", { delta = "Working" })
  h.eq("running", fixture.session.state)
  h.eq(0, fixture.review.refresh_count)
  fixture.transport:emit("turn/completed", { turn = { id = "turn-1", status = "completed" } })
  h.eq(1, fixture.review.refresh_count)
  h.eq("reviewable", fixture.session.state)
end)

h.test("auto-accepts shadow file requests but waits on command requests", function()
  local fixture = h.session_fixture()
  fixture.transport:server_request(41, "item/fileChange/requestApproval", { itemId = "f1" })
  h.eq("acceptForSession", fixture.transport.responses[41].result.decision)
  fixture.transport:server_request(42, "item/commandExecution/requestApproval", { command = { "make", "test" } })
  h.eq("waiting_for_command_approval", fixture.session.state)
  h.eq(nil, fixture.transport.responses[42])
end)
```

Extend `tests/helpers.lua` with `session_fixture`. It constructs a `fake_transport`, an already-authenticated auth double, a shadow double with fixed baseline/workspace roots, a review double that counts `refresh` and returns no files until the test changes it, and a no-op event sink. It creates `Session.new` with those dependencies, then sets `state = "idle"`, `thread_id = "thread-1"`, and `turn_id = nil` so each test begins immediately before a send.

```lua
function M.session_fixture()
  local transport = M.fake_transport({})
  local review = {
    refresh_count = 0,
    refresh = function(self, callback)
      self.refresh_count = self.refresh_count + 1
      callback(nil)
    end,
    sync_live = function(_, callback) callback(nil) end,
    files = function() return { { path = "main.lua", status = "pending" } } end,
  }
  local session = Session.new({ transport = transport, review = review,
    shadow = { workspace_root = "/shadow" }, emit = function() end })
  session.state, session.thread_id = "idle", "thread-1"
  return { session = session, transport = transport, review = review }
end
```

- [ ] **Step 2: Verify context and session tests fail**

Run: `make test TEST=tests/context_spec.lua`

Expected: FAIL because `aichatter.context` does not exist.

Run: `make test TEST=tests/session_spec.lua`

Expected: FAIL because `aichatter.session` does not exist.

- [ ] **Step 3: Implement explicit context inputs**

Restrict file context to normalized paths under the project root. Represent `@file` as a text input naming the shadow-relative path. Represent selections as text containing the path, one-based line range, and fenced source. Deduplicate files, preserve selection order, and clear one-shot context after a successful `turn/start` response.

- [ ] **Step 4: Implement the explicit session state machine**

```lua
local allowed = {
  closed = { starting = true },
  starting = { auth_required = true, idle = true, failed = true, closing = true },
  auth_required = { idle = true, failed = true, closing = true },
  idle = { running = true, closing = true },
  running = { waiting_for_command_approval = true, idle = true,
    reviewable = true, failed = true, closing = true },
  waiting_for_command_approval = { running = true, failed = true, closing = true },
  reviewable = { running = true, idle = true, closing = true },
  failed = { starting = true, reviewable = true, closing = true },
  closing = { closed = true },
}

function Session:_transition(next_state)
  assert(allowed[self.state] and allowed[self.state][next_state],
    ("invalid session transition %s -> %s"):format(self.state, next_state))
  self.state = next_state
  self:_emit("state", next_state)
end
```

`start` starts transport, checks auth, creates the shadow, and sends `thread/start` with `ephemeral = true`, `cwd = shadow.workspace_root`, `approvalPolicy = "untrusted"`, and `sandbox = "workspaceWrite"`. Before `turn/start`, `send` calls `review:sync_live`; a conflict aborts the request and emits the affected paths. Each `turn/start` sets the following exact policy. If app-server rejects `ephemeral` or `readOnlyAccess` as unsupported, enter `failed` and emit “Codex CLI is too old for aichatter.nvim; upgrade Codex and retry.” Never retry with a weaker sandbox.

```lua
sandboxPolicy = {
  type = "workspaceWrite",
  writableRoots = { shadow.workspace_root },
  readOnlyAccess = {
    type = "restricted",
    includePlatformDefaults = true,
    readableRoots = { shadow.workspace_root },
  },
  networkAccess = false,
}
```

`steer` uses `turn/steer` only while a turn is active. Both use the same ephemeral thread.

- [ ] **Step 5: Implement streaming, approvals, completion, cancellation, and one restart**

Register handlers for assistant deltas, item lifecycle events, `turn/completed`, file approvals, command approvals, errors, and process exit. Auto-respond to file approval with `{ decision = "acceptForSession" }`. Store a command server request until `approve_command` responds with the chosen Codex decision.

On completion, clear the active turn ID, call `review:refresh`, and enter `reviewable` when proposals exist or `idle` otherwise. On `cancel`, send `turn/interrupt`. On unexpected process exit, fail the active turn, restart exactly once, reinitialize, start a new ephemeral thread against the same shadow, and retain the transcript and review object; a second exit remains failed.

- [ ] **Step 6: Extend the fake app-server scenarios and run orchestration tests**

The fixture must support account-required, authenticated, streamed-turn, file-approval, command-approval, unsupported-sandbox, failed-turn, and crash-once scenarios selected by its final argv value. Add tests for follow-up prompts using the same thread, cancellation retaining shadow changes, the exact restricted sandbox payload, an actionable unsupported-sandbox failure, and restart preserving review state.

Run: `make test TEST=tests/session_spec.lua`

Expected: state, ordering, approval, cancellation, and restart cases PASS.

- [ ] **Step 7: Commit session orchestration**

```bash
git add lua/aichatter/context.lua lua/aichatter/session.lua lua/aichatter/transport.lua tests/context_spec.lua tests/session_spec.lua tests/fixtures/fake_app_server.lua tests/helpers.lua
git commit -m "feat: orchestrate isolated codex turns"
```

---

### Task 9: Build the sidebar, transcript, composer, and changed-file queue

**Files:**
- Create: `lua/aichatter/ui/init.lua`
- Create: `lua/aichatter/ui/layout.lua`
- Create: `lua/aichatter/ui/transcript.lua`
- Create: `lua/aichatter/ui/composer.lua`
- Create: `lua/aichatter/ui/changes.lua`
- Create: `tests/ui_layout_spec.lua`
- Create: `tests/ui_transcript_spec.lua`
- Create: `tests/ui_composer_spec.lua`
- Create: `tests/ui_changes_spec.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: Session events, Context, Review file records, config.
- Produces: `UI.new(session, opts)` with `:open()`, `:toggle()`, `:close()`, and `:render()`; focused view objects exposing `bufnr`, `winid`, `render(state)`, and `close()`.

- [ ] **Step 1: Write failing geometry and rendering tests**

```lua
h.test("creates transcript, changes, and 20 percent composer windows", function()
  vim.o.columns, vim.o.lines = 160, 50
  local layout = require("aichatter.ui.layout").open({ width = 0.35, composer_height = 0.20 })
  h.eq(56, vim.api.nvim_win_get_width(layout.transcript_win))
  h.eq(vim.api.nvim_win_get_width(layout.transcript_win),
    vim.api.nvim_win_get_width(layout.composer_win))
  h.eq(10, vim.api.nvim_win_get_height(layout.composer_win))
  layout:close()
end)

h.test("submits on Enter and inserts newline on Ctrl-J", function()
  local submitted
  local composer = require("aichatter.ui.composer").new({
    on_submit = function(text) submitted = text end,
  })
  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "hello" })
  h.invoke_mapping(composer.bufnr, "i", "<CR>")
  h.eq("hello", submitted)
  h.eq({ "" }, vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false))
end)

h.test("renders file counts and stable action spans", function()
  local view = require("aichatter.ui.changes").new({})
  view:render({ { path = "lua/main.lua", additions = 8, deletions = 3, status = "pending" } })
  h.matches("lua/main.lua", h.buffer_text(view.bufnr))
  h.matches("+8", h.buffer_text(view.bufnr))
  h.matches("%-3", h.buffer_text(view.bufnr))
end)
```

Extend `tests/helpers.lua` with `buffer_text(bufnr)` and `invoke_mapping(bufnr, mode, lhs)`. `invoke_mapping` makes the buffer current, enters insert mode when requested, feeds `vim.keycode(lhs)` with remapping enabled, waits for the typeahead queue, and returns to normal mode.

```lua
function M.buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.invoke_mapping(bufnr, mode, lhs)
  vim.api.nvim_set_current_buf(bufnr)
  if mode == "i" then vim.cmd("startinsert") end
  vim.api.nvim_feedkeys(vim.keycode(lhs), "mx", false)
  vim.wait(50)
  if mode == "i" then vim.cmd("stopinsert") end
end
```

- [ ] **Step 2: Verify UI tests fail for missing modules**

Run: `make test TEST=tests/ui_layout_spec.lua`

Expected: FAIL because `aichatter.ui.layout` does not exist.

- [ ] **Step 3: Implement deterministic three-window layout**

Open a right vertical split with width `floor(columns * width)`, clamped to a 40-column minimum and `columns - 40` maximum; split 50/50 when columns are below 80. Inside it, create transcript, optional changes, and composer windows. Composer height is `max(3, floor(lines * composer_height))`; changes height is its rendered line count capped at 25% of available rows.

Set `winfixwidth`, `wrap`, `number = false`, `relativenumber = false`, and scratch buffer options locally. Preserve and restore the user's prior main window on close.

- [ ] **Step 4: Implement transcript and composer views**

Transcript keeps semantic entries (`user`, `assistant`, `activity`, `error`, `approval`) and rebuilds only changed tail lines. Assistant deltas append to the active assistant entry and schedule one render per event-loop tick. Composer extracts all lines with newline joins, rejects blank submissions, clears only after `on_submit` accepts, and renders context chips as virtual text above line 0.

Install buffer-local mappings through `vim.keymap.set` using configured keys. Enter submits; Ctrl-J calls `nvim_put({ "" }, "l", true, true)` to insert a literal newline.

- [ ] **Step 5: Implement changed-file queue actions and mouse regions**

Render one row per file with relative path, signed counts, status, and `Open`, `✓`, `✕` labels. Store extmark user data or an internal line/action table mapping row and byte spans to callbacks. Keyboard `o`, `a`, and `r` act on the cursor row. A buffer-local `<LeftMouse>` handler resolves mouse position and invokes only a known action span.

- [ ] **Step 6: Run all sidebar UI tests**

Run: `make test TEST=tests/ui_layout_spec.lua`

Run: `make test TEST=tests/ui_transcript_spec.lua`

Run: `make test TEST=tests/ui_composer_spec.lua`

Run: `make test TEST=tests/ui_changes_spec.lua`

Expected: geometry, resize, streaming coalescence, submission, context, keyboard, and mouse-action cases PASS.

- [ ] **Step 7: Commit the sidebar UI**

```bash
git add lua/aichatter/ui tests/ui_*_spec.lua tests/helpers.lua
git commit -m "feat: add cursor-style ai chat sidebar"
```

---

### Task 10: Add unified hunk review, commands, and end-to-end verification

**Files:**
- Create: `lua/aichatter/ui/diff.lua`
- Create: `tests/ui_diff_spec.lua`
- Create: `tests/integration_spec.lua`
- Create: `plugin/aichatter.lua`
- Create: `README.md`
- Create: `doc/aichatter.txt`
- Create: `doc/tags`
- Create: `.github/workflows/ci.yml`
- Modify: `lua/aichatter/init.lua`
- Modify: `lua/aichatter/ui/init.lua`
- Modify: `lua/aichatter/session.lua`
- Modify: `tests/fixtures/fake_app_server.lua`
- Modify: `tests/helpers.lua`

**Interfaces:**
- Consumes: Review, UI views, Session, Context, and Config.
- Produces: unified review UI; `:AIChat`, `:AIChatLogin`, `:AIChatAddFile`, `:AIChatAddSelection`, `:AIChatCancel`, `:AIChatClose`; documented plugin installation and usage.

- [ ] **Step 1: Write failing diff-view and command tests**

```lua
h.test("renders green additions and red deletions with hunk mappings", function()
  local review = h.fake_review({ path = "main.lua", base = "old\n", candidate = "new\n" })
  local view = require("aichatter.ui.diff").open(review, "main.lua")
  local marks = vim.api.nvim_buf_get_extmarks(view.bufnr, view.namespace, 0, -1, { details = true })
  h.truthy(h.has_highlight(marks, "AIChatterDiffDelete"))
  h.truthy(h.has_highlight(marks, "AIChatterDiffAdd"))
  h.invoke_mapping(view.bufnr, "n", "a")
  h.eq(1, review.accepted_hunks[1])
end)

h.test("registers the approved commands exactly once", function()
  vim.g.loaded_aichatter = nil
  dofile("plugin/aichatter.lua")
  dofile("plugin/aichatter.lua")
  for _, name in ipairs({ "AIChat", "AIChatLogin", "AIChatAddFile",
    "AIChatAddSelection", "AIChatCancel", "AIChatClose" }) do
    h.eq(2, vim.fn.exists(":" .. name))
  end
end)
```

Extend `tests/helpers.lua` with `fake_review(record)` and `has_highlight(marks, group)`. The review double records accepted/rejected hunk IDs and returns the supplied base/candidate record; `has_highlight` checks extmark details for `hl_group == group`.

- [ ] **Step 2: Verify diff and integration tests fail**

Run: `make test TEST=tests/ui_diff_spec.lua`

Expected: FAIL because `aichatter.ui.diff` does not exist.

Run: `make test TEST=tests/integration_spec.lua`

Expected: FAIL because commands and full UI binding are absent.

- [ ] **Step 3: Implement unified diff rendering and candidate edit mode**

Render hunk headers and prefixed context, deletion, and addition lines in a non-modifiable scratch buffer. Define `AIChatterDiffAdd` and `AIChatterDiffDelete` with `default = true` links to `DiffAdd` and `DiffDelete`. Keep a line-to-hunk table so `[c`, `]c`, `a`, `r`, and `e` operate deterministically.

`e` opens an `acwrite` buffer containing the complete candidate file. Its `BufWriteCmd` gathers bytes, calls `Review:edit_candidate`, marks the candidate buffer unmodified on success, and rerenders the unified diff. It never sets the buffer name to the live project path.

- [ ] **Step 4: Wire the session singleton, commands, and UI events**

```lua
-- plugin/aichatter.lua
if vim.g.loaded_aichatter == 1 then return end
vim.g.loaded_aichatter = 1
require("aichatter")._register_commands()
```

`init.lua` must lazily construct exactly one session and UI. `AIChat` toggles it. `AIChatLogin`, `AIChatCancel`, and `AIChatClose` delegate to the session. `AIChatAddFile` validates an explicit path or calls `vim.ui.select` over project-relative regular files. `AIChatAddSelection` reads `'<` and `'>` marks and adds the selected lines. Command failures use `vim.notify` with the actionable error message.

Bind session events to transcript entries, approval rows, state indicators, and review queue refresh. Closing with proposals calls injected `vim.ui.select({ "Keep reviewing", "Discard pending changes" })`; only the explicit discard result proceeds to cleanup.

- [ ] **Step 5: Add the credential-free end-to-end test**

Use the fake process and a temporary project to execute this exact sequence:

1. Run `:AIChat` and assert three sidebar windows.
2. Submit “change main.lua”.
3. Assert assistant deltas appear while the changed-file queue remains empty.
4. Let the fake server modify only the shadow file and emit `turn/completed`.
5. Assert the real file and unsaved buffer are unchanged and the queue shows `main.lua`.
6. Open review, assert red/green extmarks, accept one hunk, and reject another.
7. Assert only the accepted hunk reached the live buffer and the disk file remains unchanged when the buffer began unsaved.
8. Close the chat, confirm discard, and assert process exit plus removal of the validated temp session directory.

Add separate integration cases for browser login URL opening, a command approval decision, cancellation, and one process restart.

- [ ] **Step 6: Write user and help documentation**

`README.md` must include lazy.nvim and packer installation examples, Neovim/Codex/Git requirements, `codex login` or `:AIChatLogin`, the six commands, default buffer-local mappings, the shadow-workspace safety model, unsaved-buffer behavior, Linux/macOS support, and the no-history/no-Windows limitations.

`doc/aichatter.txt` must define `*aichatter*`, `*aichatter-setup*`, and tags for all six commands. Run `nvim --headless --clean -u NONE -c "helptags doc" -c "qa"` and include the generated `doc/tags` file.

- [ ] **Step 7: Add minimum-version Linux CI**

Create `.github/workflows/ci.yml` with this minimum-version job. Do not run a real Codex login or network-backed turn in CI.

```yaml
name: CI
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          version: v0.10.4
          neovim: true
      - run: nvim --version
      - run: make test
```

- [ ] **Step 8: Run the complete verification suite**

Run: `make test`

Expected: every unit and integration case prints PASS and the command exits 0.

Run: `nvim --headless --clean -u tests/minimal_init.lua -c "lua require('aichatter').setup()" -c "runtime plugin/aichatter.lua" -c "lua assert(vim.fn.exists(':AIChat') == 2)" -c "qa"`

Expected: Neovim exits 0 with no Lua errors and confirms command registration.

Run: `git diff --check`

Expected: no output and exit code 0.

- [ ] **Step 9: Commit the completed v1 plugin**

```bash
git add plugin lua tests README.md doc .github Makefile
git commit -m "feat: complete aichatter.nvim v1"
```

---

## Final Manual Release Check

After all automated tasks pass, perform one real-account smoke test on Linux and one on macOS:

1. Open a disposable Git project with one unsaved buffer.
2. Sign in through `:AIChatLogin` if needed.
3. Ask Codex to modify two separate hunks and run a harmless test command.
4. Confirm the live working tree and buffer do not change before review.
5. Accept one hunk, reject the other, and confirm only the accepted content reaches the unsaved buffer.
6. Close the chat and verify its temporary session directory and app-server process are gone.

Record the tested Neovim, Codex CLI, OS, and Git versions in the release notes. Do not claim macOS support until that smoke test passes.
