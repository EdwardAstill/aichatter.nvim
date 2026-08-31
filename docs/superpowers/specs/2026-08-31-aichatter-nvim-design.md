# aichatter.nvim Design

**Date:** 2026-08-31
**Status:** Approved for implementation planning

## Summary

`aichatter.nvim` is a native Lua Neovim plugin that provides a Cursor-style Codex chat in a right sidebar. Codex completes each turn in an isolated shadow workspace. When the response ends, changed files become reviewable in the main editor as unified diffs with green additions and red deletions. Users can accept, reject, or edit individual hunks. The live project remains unchanged until a hunk is accepted.

The plugin talks directly to `codex app-server` over JSONL/JSON-RPC. It has no Node.js or Python runtime dependency and never stores authentication credentials.

## Goals

- Stream normal multi-turn Codex conversations inside Neovim.
- Sign in with ChatGPT through the official Codex browser flow.
- Give Codex full coding-agent behavior, including project inspection, commands, edits, and tests.
- Let a turn finish before presenting file changes for review.
- Keep Codex changes out of the live project until accepted.
- Review files independently and accept, reject, or edit individual hunks.
- Include unsaved Neovim buffer contents without forcing a save.
- Support automatic project discovery, `@file` context, the current buffer, and visual selections.
- Target Neovim 0.10 or newer on Linux and macOS.

## Non-goals for v1

- Persistent or browsable chat history.
- Multiple simultaneous chat sessions.
- Native Windows support.
- Direct OpenAI Responses API integration.
- A Node.js, Python, or Rust companion service.
- Per-line review inside binary files.
- Automatically resolving overlapping live and Codex edits.

## Dependencies

- Neovim 0.10 or newer.
- A `codex` executable with app-server v2 support for ephemeral root threads and restricted sandbox read access.
- Git when the selected project is a Git repository.

Project-language support is model-driven. The plugin treats project files generically and does not require language-specific adapters.

## User interface

### Sidebar

`:AIChat` toggles one resizable right-side split. Its default width is 35% of `vim.o.columns`, with a 40-column minimum and a maximum of `vim.o.columns - 40`. When the entire editor is narrower than 80 columns, the sidebar and main area each receive half the available width. It contains three stacked windows:

1. A scrollable transcript showing user messages, streamed assistant text, command activity, errors, and approval prompts.
2. A changed-file queue, visible when proposals exist and capped at 25% of the sidebar height.
3. A multiline composer occupying 20% of the sidebar height, with a minimum height of three rows.

Each changed-file row shows the relative path, added and removed line counts, review status, and Open, Accept All, and Reject All actions. Mouse actions and buffer-local keyboard actions invoke the same commands.

The transcript and queue are non-modifiable scratch buffers. The composer is a modifiable scratch buffer. Enter submits, Ctrl-J inserts a newline, and mappings are configurable.

### Main-editor review

Opening a changed file uses the normal editor area rather than squeezing a diff into the sidebar. The review buffer renders a unified diff with dedicated highlight groups linked by default to `DiffAdd` and `DiffDelete`.

Buffer-local defaults are:

- `[c` and `]c`: previous and next pending hunk.
- `a`: accept the current hunk.
- `r`: reject the current hunk.
- `e`: edit the complete proposed file.

Edit mode uses an `acwrite` candidate buffer. Its write handler updates only the shadow file, recalculates the diff, and leaves the live project untouched.

New text files use normal hunk review. A file deletion is one whole-file change. Binary files have file-level accept and reject actions only.

## Public interface

```lua
require("aichatter").setup({
  side = "right",
  width = 0.35,
  composer_height = 0.20,
})
```

The initial public commands are:

- `:AIChat`: toggle the active chat panel, creating the session on first use.
- `:AIChatLogin`: start ChatGPT sign-in through Codex.
- `:AIChatAddFile [path]`: add project file context; without a path, use `vim.ui.select`.
- `:AIChatAddSelection`: add the current visual selection.
- `:AIChatCancel`: interrupt the active Codex turn.
- `:AIChatClose`: close the session and remove its shadow workspace.

The plugin installs no mandatory global keymaps. It exposes `<Plug>` mappings and buffer-local panel/review defaults that users may override in `setup`.

## Architecture

Only one session exists per Neovim process. The project root is the Git root when available and otherwise the current working directory captured when the session starts.

### Module boundaries

- `aichatter.init`: public setup, commands, and top-level dependency checks.
- `aichatter.config`: validated defaults and user overrides.
- `aichatter.session`: explicit lifecycle and state transitions for the one active chat.
- `aichatter.transport`: app-server process ownership, JSONL framing, JSON-RPC request correlation, notifications, server requests, cancellation, and restart.
- `aichatter.auth`: account inspection and the ChatGPT browser login flow.
- `aichatter.shadow`: temporary workspace creation, manifests, live-to-shadow synchronization, buffer overlays, and guarded cleanup.
- `aichatter.diff`: text/binary detection, diff calculation, hunk application, and conflict checks.
- `aichatter.review`: proposal state, per-file/per-hunk decisions, candidate editing, and live-buffer updates.
- `aichatter.ui`: sidebar window layout and shared rendering primitives.
- `aichatter.ui.transcript`, `aichatter.ui.changes`, `aichatter.ui.composer`, and `aichatter.ui.diff`: focused buffer/window views.

Modules communicate through plain Lua tables and callbacks. UI modules render state; they do not own transport or filesystem behavior.

### Session states

The session state machine uses these externally meaningful states:

- `closed`
- `starting`
- `auth_required`
- `idle`
- `running`
- `waiting_for_command_approval`
- `reviewable`
- `failed`
- `closing`

File proposals have `pending`, `partial`, `accepted`, `rejected`, or `conflict` status. A turn may fail while still producing reviewable shadow changes.

## Codex integration

The transport starts `codex app-server --listen stdio://` with `vim.system`. It writes one JSON object per line to stdin and continuously frames stdout by newline. Stderr is captured separately for diagnostics and never fed into the JSON parser.

Startup sends `initialize`, then the `initialized` notification. Requests use monotonically increasing numeric IDs and a pending-callback table. Unknown responses, malformed JSON, and unknown notifications are reported without crashing Neovim.

The implementation relies on the official app-server surfaces documented in the [Codex App Server guide](https://developers.openai.com/codex/app-server):

- `account/read`, `account/login/start`, `account/login/completed`, and `account/updated`.
- `thread/start` with `ephemeral = true` and `cwd` set to the shadow workspace.
- `turn/start`, `turn/steer`, `turn/interrupt`, and `turn/completed`.
- `item/agentMessage/delta` and item lifecycle notifications for transcript streaming.
- Command and file-change approval requests.

The configured Codex model and reasoning effort remain the user's Codex defaults. v1 does not add a separate model picker.

### Authentication

At startup, `account/read` determines whether OpenAI authentication is required. An existing ChatGPT or API-key Codex login is reused. `:AIChatLogin` sends `account/login/start` with the managed ChatGPT browser flow, opens the returned `authUrl` through `vim.ui.open`, and waits for the completion notification. Codex owns token persistence and refresh; the plugin never reads or writes tokens. This follows the official [Codex authentication guidance](https://developers.openai.com/codex/auth).

### Approvals and sandboxing

The thread uses a workspace-write sandbox whose only writable root is the shadow workspace. Network access is disabled by default. Read access uses the app-server's restricted policy with platform defaults enabled and the shadow workspace as the sole additional readable root. Any requested access outside those boundaries requires an approval event.

File-change approvals are automatically accepted by the client because they target only the disposable shadow workspace. They are not shown to the user during the turn. Command requests that require elevated filesystem, network, or otherwise untrusted access are rendered in the sidebar and require an explicit decision. Declining leaves the turn running when the app-server permits it; cancelling interrupts the turn.

This distinction lets file work finish before review without silently approving risky access outside the shadow workspace.

## Shadow workspace

### Creation

The shadow directory is created under the operating-system temporary directory with a plugin-owned, randomly unique basename. Cleanup accepts only a normalized path that is both beneath the expected temporary parent and matches the session's recorded path.

For a Git project, the plugin runs `git clone --local --no-hardlinks` into the temporary directory to create independent Git metadata, then mirrors the live working tree over its checkout while excluding the source `.git` directory. This preserves dirty, untracked, and ignored project files while keeping shadow Git commands away from the real object store, index, branches, and refs. For a non-Git project, it recursively mirrors the project directly.

The mirror uses `vim.uv` filesystem APIs. Symlinks are recreated as symlinks; external targets are not copied, and the Codex sandbox remains responsible for denying writes outside the shadow root.

Finally, every loaded project buffer overlays its in-memory lines onto the corresponding shadow path, including modified buffers. This does not write the real buffer or real file.

### Manifests and synchronization

The plugin records a content manifest after the initial mirror. A manifest entry contains path, kind, byte size, executable bit, and content digest for regular files. After a turn, a fresh manifest detects modified, created, deleted, and binary files, including changes made by shell commands rather than Codex's file-change tool.

The shadow workspace remains alive for the chat session. A later prompt continues against its current candidate state, so the user may ask Codex to revise unaccepted work. Accepting a hunk advances the matching live and baseline content. Rejecting a hunk restores that baseline section in the shadow file. Before the next turn, files without proposals are resynchronized from live state. For files with proposals, baseline-to-live edits are also incorporated into the shadow file when their ranges do not overlap pending Codex hunks; an overlap blocks the next turn for that file until the user rejects, manually resolves, or asks Codex to retry from the live version.

## Turn and review data flow

1. The user submits composer text with optional file or selection context.
2. The session creates the shadow workspace if needed and synchronizes safe live changes.
3. `turn/start` sends the prompt to the ephemeral thread whose `cwd` is the shadow root.
4. Assistant deltas, command activity, and errors stream into the transcript.
5. Shadow file-change approvals are answered automatically; risky command approvals remain interactive.
6. `turn/completed` ends the running phase even when its status is failed or interrupted.
7. The manifest and text diff compare the session baseline with the resulting shadow tree.
8. Changed files populate the queue. No live content has changed.
9. Review actions accept, reject, or edit hunks and update queue status.
10. Follow-up prompts may run against remaining shadow proposals.

## Hunk model and conflict handling

Text diffs use `vim.diff` with index results to retain exact baseline and candidate ranges. Each hunk stores its baseline slice, proposed replacement, contextual position, and decision state.

Accepting a hunk first verifies that its baseline slice still matches the corresponding live content after accounting for previously accepted hunks. If it matches, the replacement is applied with `nvim_buf_set_lines` for a loaded buffer or an atomic file replacement for an unloaded file. A modified buffer remains modified; the plugin never invokes `:write` on the user's behalf.

If the live file changed elsewhere, non-overlapping hunks remain applicable. If the hunk's baseline slice changed, it becomes `conflict` and no automatic write occurs. The UI offers safe outcomes: reject the proposed hunk, manually incorporate it, or ask Codex to retry after the current live version is synchronized. v1 does not perform an automatic three-way merge for overlapping edits.

Accept All and Reject All iterate through still-pending hunks using the same validation and never bypass conflicts.

## Error handling and shutdown

- A missing Codex executable, or an app-server build without ephemeral-thread or restricted-read support, leaves the panel open with an actionable upgrade diagnostic.
- Missing authentication produces the sign-in action rather than a failed turn.
- A malformed protocol message fails its request or reports a notification error without invalidating unrelated pending requests.
- An unexpected app-server exit fails the active turn and restarts the server at most once. The shadow workspace and review state remain intact.
- `:AIChatCancel` sends `turn/interrupt` and retains any completed shadow changes for review.
- Shadow creation and manifest scans report progress and may be cancelled.
- Closing with pending proposals requires confirmation. Accepted live changes remain; pending candidates and the in-memory transcript are discarded.
- Closing interrupts active work, stops app-server, closes plugin buffers/windows, and removes only the validated session temporary directory.

## Testing strategy

Automated tests run under headless Neovim. A fake app-server fixture speaks JSONL over stdio, allowing deterministic protocol and UI integration tests without network access, credentials, or a real Codex turn.

### Unit coverage

- JSONL framing across partial and multiple reads.
- JSON-RPC request IDs, responses, notifications, server requests, and errors.
- Session state transitions and invalid-transition rejection.
- Manifest creation and modified/new/deleted/binary detection.
- Unsaved-buffer overlay behavior.
- Diff calculation and hunk accept, reject, edit, and conflict checks.
- Guarded temporary-path validation and cleanup.
- Sidebar text, extmarks, highlights, and buffer-local mappings.

### Integration coverage

- Initialization and existing-account detection.
- ChatGPT browser login events.
- Streaming a full assistant response before exposing file review.
- Automatic shadow file approvals and interactive command approvals.
- Follow-up turns against unaccepted shadow changes.
- Cancellation, app-server crash, one restart, and preserved review state.
- Closing with and without pending proposals.

An optional manual smoke test may use an installed Codex CLI and real account, but it is not part of credential-free CI.

## Acceptance criteria

1. Live files and buffers remain byte-for-byte unchanged throughout a Codex turn and until a hunk is accepted.
2. Unsaved buffer contents reach Codex and accepted edits return to the buffer without saving it.
3. The changed-file queue appears only after the turn completes.
4. Each text file and hunk can be reviewed and decided independently.
5. Additions and deletions render with distinct green and red highlight groups.
6. Conflicting live edits are never overwritten automatically.
7. Codex may run and test inside the shadow workspace while risky access remains approval-gated.
8. The ChatGPT browser login works without the plugin handling tokens.
9. Closing removes the ephemeral thread, in-memory transcript, and validated shadow workspace.
10. The plugin works under headless tests on Linux and is manually smoke-tested on macOS before the first release.
