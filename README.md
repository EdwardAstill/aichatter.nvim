# aichatter.nvim

`aichatter.nvim` is a native Lua Neovim sidebar for complete Codex coding-agent
turns. Codex works in an isolated shadow copy of your project, streams its
response into Neovim, and exposes proposed files only after the turn completes.
You decide which hunks reach the live buffer or file.

## Requirements

- Neovim 0.10 or newer (the minimum Linux CI version is 0.10.4).
- A `codex` CLI whose app-server supports ephemeral threads and restricted read
  access. Keep Codex current if the plugin reports an app-server compatibility
  error.
- Git for Git projects. Non-Git directories use a metadata-free local mirror.
- Linux or macOS. Native Windows support is not included in v1.

Sign in beforehand with `codex login`, or use `:AIChatLogin` after installation.
Codex owns credentials and refresh tokens; this plugin never reads or stores
them.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "eastill/aichatter.nvim",
  config = function()
    require("aichatter").setup()
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "eastill/aichatter.nvim",
  config = function()
    require("aichatter").setup()
  end,
})
```

Optional settings retain the v1 defaults shown here:

```lua
require("aichatter").setup({
  side = "right",
  width = 0.35,
  composer_height = 0.20,
  mappings = {
    submit = "<CR>",
    newline = "<C-j>",
    open = "o",
    accept = "a",
    reject = "r",
    edit = "e",
    previous_hunk = "[c",
    next_hunk = "]c",
  },
})
```

## Commands

| Command | Action |
| --- | --- |
| `:AIChat` | Toggle the single chat sidebar, creating its session on first use. |
| `:AIChatToggle` | Open or hide the chat sidebar without discarding its session or drafts. |
| `:AIChatModel` | Select an available Codex model from a picker. |
| `:AIChatModel <model>` | Use a model ID for future messages in the current chat session. |
| `:AIChatLogin` | Start Codex's managed ChatGPT browser sign-in. |
| `:AIChatAddFile [path]` | Add a contained regular project file; without a path, select one. |
| `:AIChatAddSelection` | Add the exact lines between the last visual marks. |
| `:AIChatCancel` | Interrupt the active Codex turn. |
| `:AIChatClose` | Stop Codex and remove the validated temporary session directory. |

The transcript status line shows the session state and selected model. Changing
models does not interrupt an active response; the selection applies to future
messages and is discarded when the chat session closes.

The plugin installs no mandatory global mappings. Its defaults are buffer-local:

- Composer: `<CR>` submits and `<C-j>` inserts a newline.
- Changed-file queue: `o` opens review, `a` accepts the file, and `r` rejects it.
- Hunk review: `[c`/`]c` move between pending hunks, `a` accepts, `r` rejects,
  and `e` edits the complete candidate in an `acwrite` buffer.

Each default forwards through a buffer-local `<Plug>` mapping, so custom
mappings can reuse the plugin action: `AIChatterComposerSubmit`,
`AIChatterComposerNewline`, `AIChatterChangesOpen`, `AIChatterChangesAccept`,
`AIChatterChangesReject`, `AIChatterReviewPreviousHunk`,
`AIChatterReviewNextHunk`, `AIChatterReviewAccept`, `AIChatterReviewReject`,
and `AIChatterReviewEdit`.

## Safety and unsaved buffers

Each session creates a protected baseline and writable workspace under one
validated temporary directory. Codex receives that workspace as its working
directory; its turn policy allows writes only there, restricts additional reads,
and disables network access by default. File-change approvals are automatic only
inside the disposable workspace. Risky command access remains an explicit user
decision.

Live project files and buffers remain unchanged while Codex works and while its
response streams. Proposed changes appear only after `turn/completed`. Candidate
editing writes back to the shadow workspace and recalculates the review; it never
uses the live path as the candidate buffer name. Only an accepted hunk or file
action crosses into the live project.

Loaded buffers take precedence over disk when the shadow is created. Unsaved
content is copied to the shadow without saving it. If you accept a hunk into an
unsaved buffer, the buffer remains modified and the disk file remains untouched
until you choose to write it. Closing with pending proposals requires choosing
`Discard pending changes`; cancellation or `Keep reviewing` leaves the session
open.

## v1 scope

There is one active in-memory session and no persistent or browsable chat
history. Native Windows support is not available. Linux is covered by automated
tests; macOS is a release target that still requires the documented real-account
smoke test before a release claims macOS verification.

Run `:help aichatter` for the concise built-in reference.
