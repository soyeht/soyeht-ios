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
| ST-Q-MCPA-064 | Rename workspace to an existing workspace name. | Direct MCP `rename_workspace` | Tool returns a clear duplicate-name error. Existing and target workspaces keep their previous names; no automatic suffix is applied. |
| ST-Q-MCPA-065 | Rename pane to an existing pane handle. | Direct MCP `rename_panes` | Tool returns a clear duplicate-name error. Existing and target panes keep their previous handles; no automatic suffix is applied. |

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

### macOS Window Identity and Cross-Window Routing

| ID | Case | Driver | Expected |
| --- | --- | --- | --- |
| ST-Q-MCPA-121 | List open macOS windows. | Direct MCP `list_windows` | Response includes `listedWindows`; each item has a unique `windowID`, visible title, active workspace ID/name, and nested workspace summaries. |
| ST-Q-MCPA-122 | List workspaces scoped to Window A and Window B. | Direct MCP `list_workspaces` with `windowID` or `targetWindowID` | Each response returns only workspaces owned by the requested window, and every item includes the same owning `windowID`. |
| ST-Q-MCPA-123 | List panes scoped to Window A and Window B. | Direct MCP `list_panes` with `windowID` or `targetWindowID` | Each response returns only panes in the requested window, and every item includes the same owning `windowID`. |
| ST-Q-MCPA-124 | Create a workspace in a non-active window. | Direct MCP `open_workspace` with `targetWindowID` | Workspace and panes are created in the requested window, not whichever window is currently key. Created response includes `windowID`. |
| ST-Q-MCPA-125 | Open a shell pane in a non-active window. | Direct MCP `open_shell` with `targetWindowID` | Pane is added to the requested window's active/requested workspace. Created response includes `windowID`. |
| ST-Q-MCPA-126 | Rename a workspace in Window B when Window A has similarly named workspaces. | Direct MCP `rename_workspace` with `targetWindowID` + `workspaceID` | Only the Window B workspace changes. Response includes the target `windowID`. |
| ST-Q-MCPA-127 | Rename a pane in Window B when Window A has similarly named pane handles. | Direct MCP `rename_panes` with `targetWindowID` + `conversationID` | Only the Window B pane changes. Response includes the target `windowID`. |
| ST-Q-MCPA-128 | Send input from an agent in Window A to a pane in Window B. | Direct MCP `send_pane_input` with `targetWindowID` + `conversationID` | Only the target Window B pane receives input; Window A panes are unchanged. |
| ST-Q-MCPA-129 | Move a pane from Window A to a workspace in Window B. | Direct MCP `move_pane` with source pane ID, destination workspace ID, and `destinationWindowID` | Pane lands in the requested Window B workspace; source workspace updates or closes according to normal move rules. Response includes `sourceWindowID` and `destinationWindowID`. |
| ST-Q-MCPA-130 | Close a workspace in Window B while Window A remains open. | Direct MCP `close_workspace` with `targetWindowID` + `workspaceID` | Only Window B membership/workspace is removed. Window A workspaces and panes remain listed and usable. |

### Batch Creation Layout

These cases pin the macOS app's default layout after one MCP request creates
multiple panes. They intentionally do not exercise manual `arrange_panes`,
whose row/stack/grid contract is covered by ST-Q-MCPA-070..074.

Cleanup for every case: call `close_workspace` with the created `workspaceID`
from the response, then remove any `SOYEHT_AUTOMATION_DIR` request/response
fixtures and any temp directories or worktrees created for the case. Never
delete non-`qa-even-*` or non-`qa-agent-*` paths.

The MCP batch creation tools default to a 60s response timeout because macOS
pane construction can legitimately exceed 20s when several terminals are
created and attached in one request.

| ID | Case | Concrete MCP call | Expected state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- |
| ST-Q-MCPA-131 | Create 2 panes in one macOS MCP request. | `open_workspace` with `name="qa-even-2"`, `agent="shell"`, `command=""`, `panes=[{"name":"qa-even-2-a","path":"/tmp/soyeht-even-layout/a"},{"name":"qa-even-2-b","path":"/tmp/soyeht-even-layout/b"}]`, `timeout=60`. | New workspace has exactly 2 panes. Persisted layout is a root horizontal split: pane 1 in the visual top band and pane 2 in the visual bottom band. No side-by-side root row. | Screenshot or structural dump of `workspaces.json` plus computed `PaneNode.layoutRects` table showing 1 top, 1 bottom. | PASS only if the two created panes occupy separate top/bottom bands and `close_workspace` removes the test workspace. |
| ST-Q-MCPA-132 | Create 4 panes in one macOS MCP request. | `open_workspace` with `name="qa-even-4"`, four shell panes named `qa-even-4-a`..`qa-even-4-d` under `/tmp/soyeht-even-layout/`. | New workspace has exactly 4 panes. Layout is two bands: first 2 created panes in the visual top band left-to-right, last 2 in the visual bottom band left-to-right. | Screenshot or structural dump plus computed rect table showing `top=[a,b]`, `bottom=[c,d]`. | PASS only if the layout is 2x2 and cleanup removes the workspace. |
| ST-Q-MCPA-133 | Create 6 panes in one macOS MCP request. | `open_workspace` with `name="qa-even-6"`, six shell panes named `qa-even-6-a`..`qa-even-6-f`. | New workspace has exactly 6 panes. Layout is two bands: first 3 top, last 3 bottom. | Screenshot or structural dump plus computed rect table showing `top=[a,b,c]`, `bottom=[d,e,f]`. | PASS only if the layout is 3x2, not a six-column row, and cleanup removes the workspace. |
| ST-Q-MCPA-134 | Create 8 panes in one macOS MCP request. | `open_workspace` with `name="qa-even-8"`, eight shell panes named `qa-even-8-a`..`qa-even-8-h`. | New workspace has exactly 8 panes. Layout is two bands: first 4 top, last 4 bottom. | Screenshot or structural dump plus computed rect table showing `top=[a,b,c,d]`, `bottom=[e,f,g,h]`. | PASS only if the layout is 4x2, not an eight-column row, and cleanup removes the workspace. |
| ST-Q-MCPA-135 | Codex-created panes get the same even batch layout. | `create_worktree_panes` with `repo=<test repo>`, `agent="codex"`, `names=["qa-agent-codex-a","qa-agent-codex-b","qa-agent-codex-c","qa-agent-codex-d"]`, `newWorkspace=true`, `workspaceName="qa-agent-codex"`, `timeout=60`. | Four Codex worktree panes open in the new workspace with the 2x2 layout from ST-Q-MCPA-132. | IPC response, `list_panes` agent fields, screenshot or layout dump, and worktree paths. | PASS only if all panes report `agent=codex`, layout is 2x2, workspace is closed, and created `qa-agent-codex-*` worktrees are cleaned. |
| ST-Q-MCPA-136 | Claude Code panes get the same even batch layout. | Same as ST-Q-MCPA-135 with `agent="claude"`, names `qa-agent-claude-a`..`d`, and `workspaceName="qa-agent-claude"`. | Four Claude Code panes open in 2x2. | IPC response, `list_panes`, screenshot or layout dump, and worktree paths. | PASS only if all panes report `agent=claude`, layout is 2x2, workspace/worktrees are cleaned. |
| ST-Q-MCPA-137 | OpenCode panes get the same even batch layout. | Same as ST-Q-MCPA-135 with `agent="opencode"`, names `qa-agent-opencode-a`..`d`, and `workspaceName="qa-agent-opencode"`. | Four OpenCode panes open in 2x2. | IPC response, `list_panes`, screenshot or layout dump, and worktree paths. | PASS only if all panes report `agent=opencode`, layout is 2x2, workspace/worktrees are cleaned. |
| ST-Q-MCPA-138 | Mixed `agent_race_panes` panes get the same even batch layout. | `agent_race_panes` with `repo=<test repo>`, `agents=["codex","claude","opencode","claude"]`, `prefix="qa-agent-mixed"`, `newWorkspace=true`, `workspaceName="qa-agent-mixed"`, `timeout=60`. | Four worktree panes open in one workspace with top band `[codex, claude]` and bottom band `[opencode, claude-2]` by creation order. | IPC response, `list_panes` agent fields, screenshot or layout dump, and worktree paths. | PASS only if layout is 2x2 across different agent types and cleanup removes workspace/worktrees. |
| ST-Q-MCPA-139 | Droid/Droide MCP path is documented and extensible. | If the `droid` MCP client is installed, invoke ST-Q-MCPA-131 through Droid using the registered Soyeht MCP server. Separately, direct `agent_race_panes` with `agents=["droid"]` should return the existing unknown-agent error. | Droid is currently a supported MCP client setup path in `docs/soyeht-automation.md`, not a supported pane agent in `KNOWN_AGENTS`. The layout rule is client-agnostic once the request reaches Soyeht. | Droid client transcript when available, or the direct error response: `Unknown agent(s): ['droid']`. | PASS if Droid client requests receive the same 2-band layout when the client exists; otherwise SKIP with the exact limitation and no partial worktrees. |
| ST-Q-MCPA-140 | Create 3 panes in one macOS MCP request. | `open_workspace` with `name="qa-stack-3"`, `agent="shell"`, `command=""`, `panes=[{"name":"qa-stack-3-a","path":"/tmp/soyeht-even-layout/a"},{"name":"qa-stack-3-b","path":"/tmp/soyeht-even-layout/b"},{"name":"qa-stack-3-c","path":"/tmp/soyeht-even-layout/c"}]`, `timeout=60`. | New workspace has exactly 3 panes. Persisted layout is a vertical stack: pane 1 in the visual top band, pane 2 in the middle band, and pane 3 in the bottom band. No 2+1 split and no side-by-side row. | Screenshot or structural dump plus computed rect table showing `top=a`, `middle=b`, `bottom=c` with full-width panes. | PASS only if the three created panes occupy separate top/middle/bottom bands and `close_workspace` removes the test workspace. |

## Execution Reports

- [2026-05-04 Soyeht MCP Automation](../runs/2026-05-04-soyeht-mcp-automation/report.md)
- [2026-05-05 MCP Fanout — Agent Race Panes (9 tests)](../runs/2026-05-05-mcp-fanout/report.md)
- [2026-05-05 Direct MCP Validation ST-Q-MCPA-021..104](../runs/2026-05-05-mcpa-021-104/report.md)
