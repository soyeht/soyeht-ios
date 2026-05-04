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

## Display Names

Automation keeps pane/tab names and workspace names intentionally short:

- Panes/tabs default to short hyphen names. `Fix Checkout Login` becomes
  `@fix-checkout`.
- Workspaces default to short names with normal spaces. `Investigate Checkout
  Login Regression` becomes `Investigate Checkout`.

Use `--pane-name-style space` or `--workspace-name-style full-space` only when a
user asks for that formatting. Use `verbatim` when the user asks for an exact
name.

```sh
scripts/soyeht rename-pane \
  --conversation-id 9F4C2C62-4E5E-4E9A-A8C6-1F11D31CB4D2 \
  --name "Review Payment Failure"

scripts/soyeht rename-workspace \
  --workspace-id 5747B9D7-6924-45E2-A822-A9C4E40DF02F \
  --name "Exact Workspace Name With Spaces" \
  --workspace-name-style verbatim
```

## Send Input To Existing Panes

The app can also inject text into live panes by conversation id or by handle.
The create commands print each created pane's `conversationID`.
By default this appends terminal Enter (`\r`), which is what TUI agents such as
Codex, Claude Code, and OpenCode expect for submit.

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

Use `--line-ending newline` only when you explicitly want LF (`\n`) instead of
the terminal Enter key, and `--line-ending none` for raw byte injection.

## New Workspace With Multiple Panes

Open existing directories as panes inside a brand-new Soyeht workspace:

```sh
scripts/soyeht workspace-panes \
  --workspace-name "Bug lab" \
  --agent shell \
  /tmp/repro-a /tmp/repro-b /tmp/repro-c
```

Use `--agent codex` or `--agent claude` when each pane should start an agent
instead of a plain shell.

## MCP Server

`scripts/soyeht-mcp` is a stdio MCP server for Codex, Claude Code, OpenCode, or
any other MCP client. It exposes these tools:

- `open_panes`: open new panes in existing directories.
- `open_shell`: open a new Soyeht shell pane/tab in the active workspace.
- `open_file`: open a specific or random file in `vim` or another editor inside
  a new Soyeht shell pane/tab.
- `open_workspace`: create a new Soyeht workspace containing multiple panes.
- `create_worktree_panes`: create git worktrees and open each one as a pane.
- `agent_race_panes`: create one worktree pane per agent, defaulting to `codex`,
  `claude`, and `opencode`.
- `send_pane_input`: send text directly to live panes by `conversationID` or
  handle.
- `rename_panes`: rename panes/tabs by `conversationID` or handle.
- `rename_workspace`: rename a workspace by id/name, or the active workspace by
  default.

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

Open a plain shell in a new Soyeht pane:

```json
{
  "tool": "open_shell",
  "arguments": {
    "path": "/path/to/project",
    "name": "project shell"
  }
}
```

Open a random Markdown or Swift file in `vim` inside a new Soyeht pane:

```json
{
  "tool": "open_file",
  "arguments": {
    "directory": "/path/to/project",
    "editor": "vim",
    "patterns": ["*.swift", "*.md"],
    "maxDepth": 4
  }
}
```

Open three existing directories as shell panes in a new workspace:

```json
{
  "tool": "open_workspace",
  "arguments": {
    "name": "Bug lab",
    "agent": "shell",
    "panes": [
      { "name": "one", "path": "/tmp/repro-one" },
      { "name": "two", "path": "/tmp/repro-two" },
      { "name": "three", "path": "/tmp/repro-three" }
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
    "text": "show me the diff and test output",
    "lineEnding": "enter"
  }
}
```

Rename a pane and keep the default short hyphen style:

```json
{
  "tool": "rename_panes",
  "arguments": {
    "conversationIDs": ["9F4C2C62-4E5E-4E9A-A8C6-1F11D31CB4D2"],
    "newName": "Review Payment Failure"
  }
}
```

Rename the active workspace while preserving the exact requested text:

```json
{
  "tool": "rename_workspace",
  "arguments": {
    "newName": "Exact Workspace Name With Spaces",
    "workspaceNameStyle": "verbatim"
  }
}
```
