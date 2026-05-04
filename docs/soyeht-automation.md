# Soyeht Automation CLI

Terminology used here matches Soyeht:

- **Workspace**: a top-level Soyeht workspace.
- **Pane/aba**: a terminal session inside a workspace.

The commands below have separate APIs for panes and workspaces so the two terms
do not get confused.

The Mac app watches an app-local IPC inbox:

`~/Library/Application Support/Soyeht/Automation/Requests`

The `scripts/soyeht` CLI creates git worktrees, writes a JSON request there,
and waits for the app to create Soyeht workspaces. Each workspace starts a local
PTY in its worktree, runs the requested agent command, and can receive a prompt.

## Same Agent Across Worktrees

Open each worktree as a pane in the active workspace:

```sh
scripts/soyeht worktree-panes a b c --agent codex
```

This creates:

- `~/soyeht-worktrees/<repo>/a`
- `~/soyeht-worktrees/<repo>/b`
- `~/soyeht-worktrees/<repo>/c`

and opens Soyeht panes named `a`, `b`, and `c`, each running `codex`.

Open each worktree as its own workspace:

```sh
scripts/soyeht worktree-workspaces a b c --agent codex
```

This creates:

- `~/soyeht-worktrees/<repo>/a`
- `~/soyeht-worktrees/<repo>/b`
- `~/soyeht-worktrees/<repo>/c`

and opens Soyeht workspaces named `a`, `b`, and `c`, each running `codex`.

## Compare Agents On The Same Bug

```sh
scripts/soyeht agent-race-panes \
  --prompt "Resolve the failing test for issue #123. Make the smallest correct change and explain your verification."
```

By default this creates three worktrees:

- `bug-codex`, running `codex`
- `bug-claude`, running `claude`
- `bug-opencode`, running `opencode`

and opens them as panes in the active workspace. The prompt is sent to each
agent after startup. Use `--prompt-delay-ms` if an agent needs more time before
it accepts input.

## Useful Options

```sh
scripts/soyeht worktree-panes a b c \
  --repo /path/to/repo \
  --base main \
  --worktree-root ~/tmp/soyeht-runs \
  --prompt "Work on the parser bug in this branch."
```

Use `--no-wait` when scripting from an agent and you do not need to wait for the
Mac app response.
