# agentreview.nvim Design

## Purpose

`agentreview.nvim` is a proposed separate Neovim plugin for running an
arbitrary interactive CLI coding agent in an isolated repository and reviewing
its filesystem changes before they reach the user's real checkout.

The existing `aichatter.nvim` project remains a standalone Codex App Server
client. The new project will begin from the clean published `aichatter.nvim`
revision and reuse only the isolation, automatic diff, and review code that is
useful for a generic agent. Uncommitted experiments in the current working tree
are not part of the new project's starting point.

## Product boundary

The plugin owns:

- creation and cleanup of an isolated agent environment;
- an embedded terminal containing the selected CLI agent;
- automatic changed-file and hunk discovery;
- transactional accept, reject, and ignore actions;
- conflict detection against the user's current buffers and files.

The CLI agent owns:

- authentication;
- its chat interface and history;
- model and reasoning selection;
- its own branches, commits, subagents, and temporary worktrees.

This boundary allows any interactive CLI agent to work without requiring a
protocol-specific adapter. A custom chat composer, model picker, steering API,
or message queue is outside the generic v1 design.

## Repository separation

There will be two independent projects:

1. `aichatter.nvim` remains the Codex-specific chat and review plugin already
   published at `EdwardAstill/aichatter.nvim`.
2. `agentreview.nvim` becomes the generic embedded-CLI and review plugin, with
   its own directory, Git history, and remote repository.

Creating the new project must not rewrite, rename, or force-push the existing
`aichatter.nvim` repository.

## Core architecture

```text
User's real checkout
        ^
        | accepted hunks
        |
Accepted baseline  <---- automatic comparison ---->  Agent integration worktree
                                                            ^
                                                            |
                                                   subagent branches/worktrees
```

Branches describe how agents organize their work. The accepted baseline, rather
than a branch name such as `main`, is the authority for review decisions.

The user's target is the checkout from which the session was opened. It may be
on `main`, a feature branch, or a detached commit. Accepting a change updates
that checkout's files or loaded Neovim buffers; it does not create a commit,
merge a branch, or change branch history.

## Session environment

Each session creates an independent temporary clone. A linked Git worktree of
the user's repository is not used as the isolation boundary because arbitrary
agents may commit, reset, rebase, switch branches, or modify repository
metadata. An independent clone prevents those operations from changing the
user's repository metadata.

At session creation the plugin:

1. identifies the user's current repository and checkout;
2. creates an exact accepted baseline snapshot;
3. includes dirty files, untracked files, and loaded unsaved Neovim buffers in
   that snapshot;
4. creates an independent temporary clone and an agent integration branch;
5. overlays the exact snapshot into the integration worktree;
6. starts the configured CLI command in an embedded terminal whose working
   directory is the integration worktree.

The baseline is a review-state snapshot, not merely `main` or the session's
initial Git commit. This distinction preserves unsaved and uncommitted user
state and allows the baseline to advance as individual hunks are accepted.

## Subagents and additional worktrees

The plugin reviews one designated integration worktree per session.

The CLI agent may create subagent branches or additional worktrees inside the
isolated clone. Those worktrees are private implementation details and are not
shown independently in the review queue. A subagent's result becomes visible
only after the primary agent merges, cherry-picks, copies, or otherwise
integrates it into the designated integration worktree.

This rule avoids duplicate proposals, ambiguous ordering, and conflicts between
multiple worktrees that contain overlapping versions of the same change. Direct
per-subagent review can be considered later as a separate feature; it is not
part of v1.

Agent commits do not hide changes from review. The plugin compares the accepted
baseline with the integration worktree's resulting filesystem tree, rather than
depending on whether `git status` reports committed or uncommitted changes.

## Automatic diff discovery

The agent is never asked to generate a patch or diff file. The plugin detects
changes by comparing the accepted baseline with the integration worktree.

The review queue contains modified, created, deleted, binary, symlink, and
mode-only changes. Text files are divided into stable review hunks with green
additions and red deletions. The queue refreshes after relevant filesystem
events and when Neovim regains focus.

## Review actions

### Accept hunk

Accepting a hunk performs a guarded three-way operation using:

```text
accepted baseline + current real file/buffer + agent candidate
```

If the user's current state has not changed incompatibly, the hunk is applied
to the real checkout and the same hunk advances in the accepted baseline. The
agent integration worktree retains the agent's version, so the accepted hunk
then disappears from the baseline-to-worktree comparison.

Acceptance does not automatically save a loaded unsaved buffer, create a Git
commit, stage files, or merge the integration branch.

### Reject hunk

Rejecting a hunk restores that portion of the agent integration worktree to the
accepted baseline. It does not change the user's real checkout.

The restore source is the accepted baseline, not the current contents of
`main`. The real branch may have moved or the user may have edited the same file
since the session began; treating current `main` as the source would mix
unrelated state into the agent workspace.

### Ignore hunk

Ignoring a hunk leaves both the real checkout and the agent integration
worktree unchanged. The plugin stores an in-memory fingerprint of that exact
hunk and hides it for the remainder of the session.

If the agent changes the ignored lines, their fingerprint changes and the new
hunk becomes visible again. The review UI provides a way to show ignored hunks
and restore them to the pending queue. Ignore decisions are not persisted after
the session closes.

### File-level actions

Accept, reject, and ignore file actions apply the corresponding hunk operation
to every pending hunk in that file. Binary files, symlinks, deletions, empty
files, and mode-only changes use guarded whole-file actions.

## Conflict handling

The plugin never silently overwrites an overlapping user edit. If the real
checkout or loaded buffer has changed since the accepted baseline, the plugin
attempts a three-way reconciliation:

- non-overlapping user and agent edits are preserved together;
- overlapping edits are marked as conflicts;
- conflicted hunks remain pending until the user edits, rejects, or explicitly
  resolves them.

Before accepting a file operation, the plugin revalidates filesystem type,
content identity, buffer change tick, path ancestry, and symlink boundaries.

## User interface

The side panel has two primary areas:

1. an embedded terminal running the configured CLI agent;
2. a full-line selectable changed-file queue.

Opening a changed file displays a centered floating review window. The review
supports current-hunk and remaining-hunk accept/reject actions, ignore actions,
hunk navigation, green additions, red deletions, and complete-candidate editing.
Contextual `?` help documents the active buffer's mappings.

The terminal is the agent's chat surface. This keeps login, model choice,
reasoning level, slash commands, streaming, and subagent controls native to each
CLI instead of duplicating incompatible behavior in the plugin.

## Session cleanup

Closing a session with pending visible or ignored changes requires explicit
confirmation. After confirmation, the plugin stops the terminal job and removes
the isolated clone, integration worktree, subagent worktrees located inside the
session directory, accepted baseline, and session-only ignore records.

Cleanup is restricted to a validated randomly named session directory. The
plugin must not recursively delete the user's repository or any worktree outside
that directory.

## v1 non-goals

- A protocol-neutral custom chat composer.
- Plugin-managed model or reasoning controls.
- Persistent chat, queue, or ignore history.
- Direct review of every subagent worktree.
- Automatic commits, staging, merges, rebases, or pushes in the user's checkout.
- Native Windows support.
- Containment of an unrestricted CLI process outside the isolated clone. The
  clone protects normal repository operations, but strong process containment
  would require an optional operating-system sandbox or container.

## Success criteria

The first release is successful when a user can:

1. configure and launch an arbitrary interactive CLI agent;
2. chat with it inside an embedded Neovim terminal;
3. see automatic file and hunk changes from the integration worktree;
4. accept, reject, or ignore individual hunks and whole files;
5. preserve non-overlapping live and unsaved edits;
6. receive an explicit conflict instead of an overwrite;
7. close the session without leaving temporary repository state behind;
8. use `aichatter.nvim` independently without either repository depending on
   the other.
