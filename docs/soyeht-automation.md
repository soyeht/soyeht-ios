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

## Send Input To Existing Panes

The app can also inject text into live panes by conversation id or by handle.
The create commands print each created pane's `conversationID`.

```sh
scripts/soyeht send-pane-input \
  --conversation-id 9F4C2C62-4E5E-4E9A-A8C6-1F11D31CB4D2 \
  --text "continue from here"
```

Handles such as `codex`, `claude`, `opencode`, `codex-2`, and `shell` are also
accepted:

```sh
scripts/soyeht send-pane-input --handle codex --text "run the tests"
```

## MCP Server

`scripts/soyeht-mcp` is a stdio MCP server for Codex, Claude Code, OpenCode, or
any other MCP client. It exposes these tools:

- `open_panes`: open new panes in existing directories.
- `create_worktree_panes`: create git worktrees and open each one as a pane.
- `agent_race_panes`: create one worktree pane per agent, defaulting to `codex`,
  `claude`, and `opencode`.
- `send_pane_input`: send text directly to live panes by `conversationID` or
  handle.

The Soyeht Mac app must be running because the MCP server writes requests to the
same app-local IPC inbox used by the CLI.

### Codex

From this repository:

```sh
codex mcp add soyeht -- "$(pwd)/scripts/soyeht-mcp"
```

### Claude Code

From this repository:

```sh
claude mcp add soyeht -- "$(pwd)/scripts/soyeht-mcp"
```

### OpenCode

Add this entry to `~/.config/opencode/opencode.json`, using this repository's
absolute path:

```json
{
  "mcp": {
    "soyeht": {
      "type": "local",
      "command": ["/absolute/path/to/iSoyehtTerm-soyeht-mcp/scripts/soyeht-mcp"],
      "enabled": true
    }
  }
}
```

### MCP Call Examples

Open three existing directories as panes running Codex:

```json
{
  "tool": "open_panes",
  "arguments": {
    "agent": "codex",
    "panes": [
      { "name": "a", "path": "/tmp/repo-a" },
      { "name": "b", "path": "/tmp/repo-b" },
      { "name": "c", "path": "/tmp/repo-c" }
    ]
  }
}
```

Create worktrees for Codex, Claude Code, and OpenCode, then send each one the
same prompt after startup:

```json
{
  "tool": "agent_race_panes",
  "arguments": {
    "repo": "/path/to/repo",
    "prefix": "bug-123",
    "prompt": "Resolve this bug, make the smallest correct change, and run verification."
  }
}
```

Send a follow-up directly to one of the created panes:

```json
{
  "tool": "send_pane_input",
  "arguments": {
    "conversationIDs": ["9F4C2C62-4E5E-4E9A-A8C6-1F11D31CB4D2"],
    "text": "show me the diff and test output"
  }
}
```
