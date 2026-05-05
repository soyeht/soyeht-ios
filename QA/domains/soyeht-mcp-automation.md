# Soyeht MCP Automation

Profile: full
Automation: auto + assisted agent runs
Device: No

This domain covers the Soyeht local automation IPC, CLI, and MCP server used by
Codex, Claude Code, OpenCode, and other MCP clients to create panes/workspaces,
send input, rename items, open shells/files, and rearrange pane layouts.

## Scope

- `scripts/soyeht-mcp` stdio JSON-RPC transport.
- `scripts/soyeht` CLI request path.
- Soyeht Mac app automation request handlers.
- Live pane targeting by `conversationID` and handle.
- Agent-driven use through Codex, Claude Code, and OpenCode.
- Pane layout automation: stack, row, grid, spotlight, zoom, and unzoom.

## Cases

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-001 | Initialize MCP over newline-delimited JSON-RPC. | Direct MCP | Server info and tools capability are returned. |
| ST-Q-MCPA-002 | Initialize MCP over `Content-Length` framed JSON-RPC. | Direct MCP | Response uses the same framed transport. |
| ST-Q-MCPA-003 | List all Soyeht automation tools. | Direct MCP | Tool list includes workspace, pane, shell/file, send, rename, arrange, and emphasize tools. |
| ST-Q-MCPA-004 | Create a workspace with shell panes. | Direct MCP `open_workspace` | Panes open in requested directories and share one workspace id. |
| ST-Q-MCPA-005 | Add panes to the active workspace. | Direct MCP `open_panes`/`open_shell` | New panes are added without creating an unintended workspace. |
| ST-Q-MCPA-006 | Create git worktree panes. | Direct MCP `create_worktree_panes` | Worktrees/branches are created and opened as panes. |
| ST-Q-MCPA-007 | Create an agent race in panes. | Direct MCP `agent_race_panes` | Codex, Claude Code, and OpenCode processes start in separate worktrees. |
| ST-Q-MCPA-008 | Send input by `conversationID`. | Direct MCP/CLI `send_pane_input` | Only targeted panes receive the payload. |
| ST-Q-MCPA-009 | Send input by handle. | Direct MCP/CLI `send_pane_input` | Handle lookup prefers the active workspace and sends to the matching pane. |
| ST-Q-MCPA-010 | Validate input terminators. | Direct MCP `send_pane_input` | `enter`, `newline`, and `none` produce CR, LF, and no terminator respectively. |
| ST-Q-MCPA-011 | Rename panes with default naming. | Direct MCP/CLI `rename_panes` | Pane handles default to short hyphen names. |
| ST-Q-MCPA-012 | Rename workspaces with default naming. | Direct MCP/CLI `rename_workspace` | Workspace names default to short names with normal spaces. |
| ST-Q-MCPA-013 | Open a shell pane without a bogus command. | Direct MCP `open_shell` | A plain shell opens and accepts follow-up input. |
| ST-Q-MCPA-014 | Open a specific or random file in an editor. | Direct MCP `open_file` | File opens in a new Soyeht pane, not Terminal.app. |
| ST-Q-MCPA-015 | Arrange panes as stack/row/grid. | Direct MCP/CLI `arrange_panes` | Workspace layout persists top-to-bottom, side-by-side, and tiled modes. |
| ST-Q-MCPA-016 | Arrange selected panes while preserving others. | Direct MCP `arrange_panes` | Selected panes are grouped and non-target panes stay visible. |
| ST-Q-MCPA-017 | Preserve requested handle order. | Direct MCP `arrange_panes` | Persisted leaf order follows the requested handle order. |
| ST-Q-MCPA-018 | Spotlight panes. | Direct MCP/CLI `emphasize_pane` | Target pane becomes larger at the requested side/ratio with siblings visible. |
| ST-Q-MCPA-019 | Zoom and unzoom panes. | Direct MCP `emphasize_pane` | Zoom renders a single pane temporarily; unzoom restores split rendering. |
| ST-Q-MCPA-020 | Drive workflows through agents. | Codex, Claude Code, OpenCode | Agents call Soyeht MCP tools directly and resulting layouts persist in the app. |

### Agent Race Variants

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-021 | Start a 2-agent race (claude + opencode only). | Claude Code `agent_race_panes` | 2 worktrees and 2 panes created; codex is not launched. |
| ST-Q-MCPA-022 | Start a 5-agent race with repeated agent types (e.g., 3× claude, 1× opencode, 1× codex). | Claude Code `agent_race_panes` | 5 distinct worktrees created; branch names use per-agent counter suffix (e.g. `prefix-claude-1`, `prefix-claude-2`). App display name may strip the numeric suffix but `handle` and `path` stay unique. |
| ST-Q-MCPA-023 | Start an agent race with a custom prefix (e.g., `prefix="fix-auth"`). | Claude Code `agent_race_panes` | Worktree dirs are named `fix-auth-claude`, `fix-auth-opencode`, etc. |
| ST-Q-MCPA-024 | Start a race with `newWorkspace=true` and a custom `workspaceName`. | Claude Code `agent_race_panes` | New workspace is created with the exact requested name; all agent panes open inside it. |
| ST-Q-MCPA-025 | Start a race with `prompt` and `promptDelayMs=3000`. | Claude Code `agent_race_panes` | Panes open first; prompt is sent after the 3-second delay; Enter fires. |
| ST-Q-MCPA-026 | Start an agent race on a repo with no existing git history. | Claude Code `agent_race_panes` | Tool returns an error or graceful message; no partial worktrees left on disk. |
| ST-Q-MCPA-027 | Start a race with `agents=["claude"]` (single agent via `agent_race_panes` instead of `create_worktree_panes`). | Claude Code `agent_race_panes` | Exactly 1 worktree and 1 pane; tool completes without error. |

### Worktree Panes — Single Agent

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-030 | Create a single codex worktree pane with a prompt. | Codex `create_worktree_panes` | Worktree created, codex starts in that dir, prompt delivered and executed. |
| ST-Q-MCPA-031 | Create a worktree pane with `newWorkspace=true`. | Claude Code `create_worktree_panes` | Worktree opens in a new workspace, not appended to the current one. |
| ST-Q-MCPA-032 | Create a worktree pane with a custom branch name. | Direct MCP `create_worktree_panes` | Branch is checked out with the supplied name; pane title reflects it. |
| ST-Q-MCPA-033 | Create 10 worktree panes sequentially via `create_worktree_panes` (stress). | Direct MCP | All 10 worktrees created; no IPC timeout; panes visible in the workspace. |

### Shell and File Panes

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-040 | Open a shell pane in a specific directory, then send a command. | Claude Code `open_shell` + `send_pane_input` | Shell launches in the correct cwd; command executes and output appears. |
| ST-Q-MCPA-041 | Open multiple shell panes in different directories in one call. | Direct MCP `open_panes` | Each pane reflects its own cwd; panes do not bleed into each other. |
| ST-Q-MCPA-042 | Open a file in the Soyeht editor pane. | Direct MCP `open_file` | File opens inside Soyeht, not in an external editor. |
| ST-Q-MCPA-043 | Open a non-existent file path. | Direct MCP `open_file` | Tool returns an error; no blank/crashed pane created. |
| ST-Q-MCPA-044 | Open a shell pane with a long-running process (e.g., `tail -f /tmp/test.log`). | Claude Code `open_shell` + `send_pane_input` | Process runs in background; subsequent `send_pane_input` to that pane appends to log. |

### Send Pane Input — Multi-target and Edge Cases

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-050 | Send the same prompt to 3 panes by `conversationID` in a single agent turn. | Claude Code (3× `send_pane_input`) | All 3 panes receive the message; no cross-pane contamination. |
| ST-Q-MCPA-051 | Send input with `terminator=none` and verify no Enter is injected. | Direct MCP `send_pane_input` | Text appears in pane buffer but the command is not executed. |
| ST-Q-MCPA-052 | Send input with `terminator=newline` (LF vs CR). | Direct MCP `send_pane_input` | LF is sent; behavior verified with a shell that distinguishes LF from CR. |
| ST-Q-MCPA-053 | Send empty string payload. | Direct MCP `send_pane_input` | Tool returns an error or no-op; pane is not disrupted. |
| ST-Q-MCPA-054 | Send input to a pane by handle after the pane has been renamed. | Direct MCP `rename_panes` + `send_pane_input` | Handle lookup resolves by new name; input delivered. |
| ST-Q-MCPA-055 | Send input to a stale/closed pane (pane no longer exists). | Direct MCP `send_pane_input` | Tool returns a clear error; no silent failure. |

### Rename Operations

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-060 | Rename multiple panes by providing each pane's `conversationID` explicitly (one call per pane). | Claude Code `rename_panes` | Each targeted pane is renamed to its new name; `rename_panes` requires explicit targets — no "rename all" shortcut exists. |
| ST-Q-MCPA-061 | Rename a single pane by `conversationID`. | Direct MCP `rename_panes` | Only the targeted pane is renamed; others are unaffected. |
| ST-Q-MCPA-062 | Rename workspace to a name with spaces and Unicode. | Direct MCP `rename_workspace` | Workspace name updates correctly; spaces and accented chars preserved. |
| ST-Q-MCPA-063 | Rename workspace to an empty string. | Direct MCP `rename_workspace` | Tool returns an error or reverts to a default name; no blank title shown. |

### Layout — Arrange and Emphasize

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-070 | Arrange 3 panes as `grid`. | Direct MCP `arrange_panes` | Panes tile in a 2+1 or 3-column layout without overlapping. |
| ST-Q-MCPA-071 | Arrange 4 panes as `row` then switch to `stack`. | Direct MCP `arrange_panes` | First call produces side-by-side; second call restores top-to-bottom without losing panes. |
| ST-Q-MCPA-072 | Arrange a subset of panes by handle while leaving others untouched. | Direct MCP `arrange_panes` | Only named panes are repositioned; unlisted panes keep their existing position. |
| ST-Q-MCPA-073 | Emphasize (spotlight) pane at `right` side with 0.7 ratio. | Direct MCP `emphasize_pane` | Target pane occupies 70% of the right side; sibling panes share the remaining 30%. |
| ST-Q-MCPA-074 | Zoom a pane, send input, then unzoom. | Direct MCP `emphasize_pane` (zoom) + `send_pane_input` + `emphasize_pane` (unzoom) | Pane accepts input while zoomed; sibling layout is restored after unzoom. |
| ST-Q-MCPA-075 | Emphasize a pane that does not exist. | Direct MCP `emphasize_pane` | Tool returns a clear error; other panes are unaffected. |

### Workspace Management

> **Note:** `create_workspace_panes` (used by `open_workspace`, `agent_race_panes newWorkspace=true`, and `create_worktree_panes newWorkspace=true`) slows down when the app has many open panes. Use a timeout ≥ 60 s in automated test runs that have accumulated many tabs.

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-080 | Open a new workspace with `open_workspace` then add panes with `open_panes`. | Direct MCP | Workspace created; subsequent `open_panes` targets that workspace by ID. |
| ST-Q-MCPA-081 | Open two named workspaces in the same session and verify distinct IDs. | Direct MCP `open_workspace` ×2 | Two separate workspaces exist; IDs differ; panes in one do not bleed into the other. |
| ST-Q-MCPA-082 | Open a workspace when an existing workspace with the same name is present. | Direct MCP `open_workspace` | Tool either reuses the existing workspace or creates a new one with a deduplicated name — does not crash. |

### Natural Language Prompts (Agent Comprehension)

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-090 | Ask agent in PT-BR: "abre 3 agentes no repositório atual em worktrees separadas". | Claude Code | Agent maps the request to `agent_race_panes` with default agents and no extra params. |
| ST-Q-MCPA-091 | Ask agent in PT-BR: "abre claude e opencode no mesmo repo, cada um numa aba nova e manda mensagem 'olá'". | Claude Code | Agent uses `agent_race_panes` with `agents=["claude","opencode"]` and `prompt="olá"`. |
| ST-Q-MCPA-092 | Ask agent: "create 3 agents in a brand new workspace named 'sprint-42'". | Claude Code | Agent uses `agent_race_panes` with `newWorkspace=true`, `workspaceName="sprint-42"`. |
| ST-Q-MCPA-093 | Ask agent: "put all panes side by side". | Claude Code | Agent maps to `arrange_panes` with layout `row`. |
| ST-Q-MCPA-094 | Ask agent: "highlight the claude pane and make it bigger on the right". | Claude Code | Agent maps to `emphasize_pane` with `side="right"` and a ratio ≥ 0.6. |
| ST-Q-MCPA-095 | Ask agent in a multi-turn conversation to first open agents, then rename panes, then send a follow-up prompt. | Claude Code | All three tool calls succeed in sequence; IDs from step 1 are reused in steps 2 and 3. |

### Error Handling and Resilience

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-100 | Call `agent_race_panes` with an unsupported agent name (e.g., `"gemini"`). | Direct MCP | Tool returns a clear error listing valid agent names; no partial worktrees created. |
| ST-Q-MCPA-101 | Call `agent_race_panes` with `repoPath` pointing to a non-git directory. | Direct MCP | Tool returns an error; no panes created. |
| ST-Q-MCPA-102 | IPC response times out (Soyeht app not running). | Direct MCP any tool | Tool returns a timeout error within the configured deadline; no hanging call. |
| ST-Q-MCPA-103 | Send a malformed JSON-RPC request to the MCP server. | Direct (raw stdin) | Server returns a JSON-RPC error response without crashing. |
| ST-Q-MCPA-104 | Restart the MCP server mid-session and call a tool immediately. | Codex `agent_race_panes` | Server reinitializes cleanly; the tool call succeeds after the natural reconnect. |

### List, Close, Move Operations

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-105 | List all workspaces. | Direct MCP `list_workspaces` | Response includes `listedWorkspaces` with `workspaceID`, `name`, and `paneCount` for every open workspace. |
| ST-Q-MCPA-106 | List all panes across all workspaces. | Direct MCP `list_panes` | Response includes `listedPanes` with `conversationID`, `workspaceID`, `handle`, `path`, and `agent` for every open pane. |
| ST-Q-MCPA-107 | List panes filtered by workspaceID. | Direct MCP `list_panes` | Only panes belonging to the requested workspace are returned. |
| ST-Q-MCPA-108 | Close a non-last pane by conversationID. | Direct MCP `close_pane` | Pane is removed; `closedPanes` is populated; subsequent `list_panes` does not include the closed pane. |
| ST-Q-MCPA-109 | Attempt to close the only pane in a workspace. | Direct MCP `close_pane` | Tool returns a clear error: "Cannot close the last pane in a workspace. Use close_workspace instead." |
| ST-Q-MCPA-110 | Move a pane (sole pane in source) to another workspace. | Direct MCP `move_pane` | Pane appears in destination workspace; source workspace is automatically closed. `movedPanes` is populated with correct source/destination workspace IDs. |
| ST-Q-MCPA-111 | Move a pane from a multi-pane workspace to another workspace. | Direct MCP `move_pane` | Pane appears in destination workspace; source workspace retains its remaining panes. |
| ST-Q-MCPA-112 | Move pane with `destinationWorkspaceName` instead of ID. | Direct MCP `move_pane` | Tool resolves the destination workspace by name and moves the pane correctly. |
| ST-Q-MCPA-113 | Close a workspace by workspaceID. | Direct MCP `close_workspace` | Workspace and all its panes are removed; `closedWorkspaces` is populated; subsequent `list_workspaces` does not include the closed workspace. |
| ST-Q-MCPA-114 | Close a workspace by name. | Direct MCP `close_workspace` | Same as above but resolved by name match. |
| ST-Q-MCPA-115 | Attempt to close the only remaining workspace. | Direct MCP `close_workspace` | Tool returns a clear error: "Cannot close the last workspace." |

### Pane Status

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-116 | Call `get_pane_status` with no filters. | Direct MCP | Response includes `paneStatuses`; each entry has `conversationID`, `workspaceID`, `handle`, `agent`, `status`; `status` is one of `active`, `idle`, `dead`, `mirror`, `not_live`. |
| ST-Q-MCPA-117 | Open a new shell pane then query its status by `conversationID`. | Direct MCP | The pane appears in `paneStatuses` with `status` = `active` or `idle`; `agent` = `"shell"`. |
| ST-Q-MCPA-118 | Query pane status filtered by handle. | Direct MCP | Only panes whose handle matches the requested value are returned. |
| ST-Q-MCPA-119 | Poll `get_pane_status` repeatedly until all targeted panes reach `dead`. | Direct MCP + shell | Exit codes propagate: once the process exits, `status` = `dead` and `exitCode` is present. |
| ST-Q-MCPA-120 | Query `get_pane_status` for a `conversationID` that exists in `ConversationStore` but has no live `PaneViewController`. | Direct MCP | Entry is returned with `status` = `not_live`. |

## Execution Reports

- [2026-05-04 Soyeht MCP Automation](../runs/2026-05-04-soyeht-mcp-automation/report.md)
- [2026-05-05 MCP Fanout — Agent Race Panes (9 tests)](../runs/2026-05-05-mcp-fanout/report.md)
- [2026-05-05 Direct MCP Validation ST-Q-MCPA-021..104](../runs/2026-05-05-mcpa-021-104/report.md)
