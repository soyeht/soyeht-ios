# Soyeht MCP Use Cases

Date: 2026-05-04

This matrix captures expected behavior for the Soyeht automation MCP. The test
run uses an isolated Soyeht app environment with temporary repositories,
worktrees, and pane loggers so it does not mutate the user's normal workspace
state.

Run result: 20/20 PASS.

Notes:

- macOS canonicalizes `/tmp/...` to `/private/tmp/...` inside PTYs; path checks
  compare the canonical cwd.
- Agent-driven isolated tests pass `automationDir` explicitly in tool arguments
  because MCP subprocess environment inheritance is client-dependent.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| UC-01 | MCP protocol initializes over newline-delimited JSON-RPC. | Direct MCP | `initialize` returns server info and tool capability. | PASS | `serverInfo.name=soyeht-automation`, tools capability present. |
| UC-02 | MCP protocol initializes over `Content-Length` framed JSON-RPC. | Direct MCP | `initialize` response uses the same framed transport. | PASS | Response returned `Content-Length: 173`. |
| UC-03 | MCP lists all automation tools. | Direct MCP | Tool list includes `open_workspace`, `open_panes`, `create_worktree_panes`, `agent_race_panes`, `send_pane_input`, `rename_panes`, and `rename_workspace`. | PASS | All seven expected tools listed. |
| UC-04 | Create a new workspace with one shell pane. | Direct MCP `open_workspace` | One workspace and one pane are created; shell runs in requested directory. | PASS | Shell logger reported ready in canonical cwd. |
| UC-05 | Create a new workspace with four shell panes. | Direct MCP `open_workspace` | One workspace is created; all four panes share the same workspace id and each shell cwd matches its requested directory. | PASS | Four shell loggers ready; all returned panes shared one workspace id. |
| UC-06 | Send input to one pane by `conversationID`. | Direct MCP `send_pane_input` | Only that pane receives the message. | PASS | Target count `[1, 0, 0, 0]`. |
| UC-07 | Send input to multiple panes by `conversationID`. | Direct MCP `send_pane_input` | All targeted panes receive the same message exactly once. | PASS | Target counts `[1, 1, 1, 1]`. |
| UC-08 | Send input to one pane by handle. | Direct MCP `send_pane_input` | The pane with the requested handle receives the message. | PASS | `shell-2` received it; sibling counts `[0, 1, 0, 0]`. |
| UC-09 | Send raw input without appending a newline. | Direct MCP `send_pane_input` | Target receives bytes even when `appendNewline=false`. | PASS | Raw logger recorded `RAW:abcde`. |
| UC-10 | Open additional panes inside the active workspace. | Direct MCP `open_panes` | New panes are added to the current workspace instead of creating another workspace. | PASS | Returned workspace id matched the active four-pane workspace. |
| UC-11 | Create git worktrees as panes in the active workspace. | Direct MCP `create_worktree_panes` | Worktree directories and branches are created; panes open in those directories. | PASS | Two worktree panes created; `.git` files and branches present. |
| UC-12 | Open Codex, Claude Code, and OpenCode in separate worktree panes. | Direct MCP `agent_race_panes` | Three panes start real `codex`, `claude`, and `opencode` processes with cwd set to their worktrees. | PASS | Process tree showed all three agents with cwd in `race-*` worktrees. |
| UC-13 | CLI creates a new workspace with multiple shell panes. | `scripts/soyeht workspace-panes` | CLI queues `create_workspace_panes`; app returns one workspace and N panes. | PASS | CLI returned two pane `conversationID`s and both loggers were ready. |
| UC-14 | CLI sends input to a pane by `conversationID`. | `scripts/soyeht send-pane-input` | Target pane receives the CLI message. | PASS | CLI returned `sent pane @shell`; target logger received `UC14_CLI`. |
| UC-15 | Invalid directory fails cleanly. | Direct MCP `open_workspace` | Tool returns `isError=true`; app does not create panes for the invalid path. | PASS | Tool returned `Directory does not exist`. |
| UC-16 | Empty send target fails cleanly. | Direct MCP `send_pane_input` | Tool returns `isError=true` with no pane mutation. | PASS | Tool returned `No pane input targets were provided.` |
| UC-17 | Codex agent sends a message to another Soyeht pane. | `codex exec` using MCP | Codex calls `send_pane_input`; the target pane log receives the message. | PASS | Codex logged `soyeht/send_pane_input (completed)` and target received `UC17_CODEX_AGENT_EXTERNAL`. |
| UC-18 | Codex agent creates a new Soyeht workspace with two shell panes. | `codex exec` using MCP | Codex calls `open_workspace`; both pane loggers report ready in their requested directories. | PASS | Codex logged `soyeht/open_workspace (completed)`; both loggers ready. |
| UC-19 | Codex agent sends follow-up input to panes it created. | `codex exec` using MCP | Codex uses returned `conversationID`s and both created panes receive the follow-up. | PASS | Codex logged `soyeht/send_pane_input (completed)`; both created panes received `UC19_CODEX_CREATED`. |
| UC-20 | App UI reflects the automation result. | Accessibility snapshot | Soyeht shows the created workspace tab and expected pane handles. | PASS | AX snapshot showed `Single Shell Lab`, `Four Shell Lab`, `CLI Lab`, `Codex Created Lab`, and active `shell`/`shell-2` panes. |

## Regression Checks: Names And Input Terminators

Date: 2026-05-04

Run result: 18/18 PASS.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| RG-01 | MCP protocol still initializes after adding rename tools. | Direct MCP | `serverInfo.name=soyeht-automation`. | PASS | Server initialized. |
| RG-02 | Workspace creation applies default workspace naming. | Direct MCP `open_workspace` | Long workspace name becomes a short space name. | PASS | `Investigate Checkout Login Regression` became `Investigate Checkout`. |
| RG-03 | Pane creation applies default pane/tab naming. | Direct MCP `open_workspace` | Long pane name becomes a short hyphen name. | PASS | `Fix Checkout Login` became `Fix-Checkout` with handle `@fix-checkout`. |
| RG-04 | Additional pane creation keeps short hyphen names. | Direct MCP `open_workspace` | Another long pane name is shortened consistently. | PASS | `Long Pane Name With Spaces` became `Long-Pane` with handle `@long-pane`. |
| RG-05 | Workspace rename defaults to short space names. | Direct MCP `rename_workspace` | Long rename is shortened to one or two words. | PASS | `Workspace Name With Many Words` became `Workspace Name`. |
| RG-06 | Workspace rename can preserve an exact requested name. | Direct MCP `rename_workspace` with `workspaceNameStyle=verbatim` | Exact text is stored. | PASS | Stored `Exact Workspace Name With Spaces`. |
| RG-07 | Workspace rename can use explicit hyphen style when requested. | Direct MCP `rename_workspace` with `workspaceNameStyle=hyphen` | Workspace name uses hyphen separator. | PASS | `Explicit Hyphen Workspace` became `Explicit-Hyphen`. |
| RG-08 | Pane rename defaults to short hyphen names. | Direct MCP `rename_panes` | Long rename becomes a short hyphen handle. | PASS | `Review Payment Failure` became `@review-payment`. |
| RG-09 | Pane rename can use explicit spaces when requested. | Direct MCP `rename_panes` with `paneNameStyle=space` | Handle preserves spaces. | PASS | `Manual Space Name` became `@manual space`. |
| RG-10 | Default `send_pane_input` submits a shell command. | Direct MCP `send_pane_input` | Shell `read` receives the submitted line. | PASS | Logger recorded `LINE:DEFAULT_ENTER`. |
| RG-11 | Raw TUI-style reader starts for Enter probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-12 | Default/`enter` input sends terminal Enter. | Direct MCP `send_pane_input` with `lineEnding=enter` | PTY receives CR (`0d`). | PASS | Raw bytes `48454c4c4f0d`. |
| RG-13 | Raw TUI-style reader starts for newline probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-14 | Explicit `newline` input sends LF. | Direct MCP `send_pane_input` with `lineEnding=newline` | PTY receives LF (`0a`). | PASS | Raw bytes `48454c4c4f0a`. |
| RG-15 | Raw TUI-style reader starts for no-terminator probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-16 | Explicit `none` input sends no terminator. | Direct MCP `send_pane_input` with `lineEnding=none` | PTY receives only payload bytes. | PASS | Raw bytes `48454c4c4f`. |
| RG-17 | CLI exposes pane rename command. | `scripts/soyeht rename-pane --help` | Help includes name-style options. | PASS | `--pane-name-style` listed. |
| RG-18 | CLI exposes workspace rename command. | `scripts/soyeht rename-workspace --help` | Help includes workspace-name-style options. | PASS | `--workspace-name-style` listed. |
