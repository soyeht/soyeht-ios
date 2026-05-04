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

## Execution Reports

- [2026-05-04 Soyeht MCP Automation](../runs/2026-05-04-soyeht-mcp-automation/report.md)
