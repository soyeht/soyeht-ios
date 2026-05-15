---
id: mac-dev-workflow
ids: ST-Q-MDEV-001..011
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Developer Workflow — Local + Remote Side-by-Side

## Objective
Verify the primary developer use case: a local shell tab navigated to a local git repository open alongside a Soyeht instance tab connected to the same project on a Linux server. Tests cover instance picker (workspace create/resume logic), clipboard bridge between tabs, and tab independence.

## Risk
- Instance picker calls `buildWebSocketURL` without first calling `createWorkspace` → WS session ID is invalid → connection fails or connects to wrong session
- Picker calls `createWorkspace` even when a workspace already exists → creates duplicate sessions
- Clipboard copy from one terminal pastes into the wrong tab (NSPasteboard key-down event going to wrong first responder)
- Local shell tab blocks or freezes when Soyeht tab is reconnecting

## Preconditions
- macOS app logged in, server reachable
- At least one online instance with terminal capability
- Local git repo at `~/Documents/SwiftProjects/iSoyehtTerm-macos` (or substitute any local repo path)
- That repo (or a sibling project) is also present on the Soyeht server instance

## Fixtures
- Workspaces created during test should be named `test-qa-mac-ws-*`

## How to automate
- **Type into specific tab**: Click on tab first (`mcp__XcodeBuildMCP__tap` on tab title), then `type_text`
- **Read tab output**: `mcp__XcodeBuildMCP__screenshot` + OCR
- **Clipboard bridge**: `type_text` selects all + copies in tab 1; then focus tab 2 + paste
- **Instance picker**: Use accessibility identifiers on NSTableView rows; `mcp__XcodeBuildMCP__tap` to select

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MDEV-001 | Open local shell tab → `cd ~/Documents/SwiftProjects/iSoyehtTerm-macos` → `git status` | Correct branch and file status shown. No errors. This is the local Mac repo | P0 | Yes |
| ST-Q-MDEV-002 | Click toolbar "+" → "New Soyeht Tab…" → instance picker opens | Popover or sheet appears listing available instances with status (running/provisioning) | P0 | Yes |
| ST-Q-MDEV-003 | In instance picker: select an instance that already has a workspace | **No** `createWorkspace` call made. WS URL uses existing `workspace.sessionName`. Terminal connects | P0 | Yes — verify via server logs or absence of POST to `/workspace` |
| ST-Q-MDEV-004 | In instance picker: select an instance with **no** existing workspace | `createWorkspace(container:)` called (POST `/workspace`). `workspace.sessionId` used in WS URL. Terminal connects | P0 | Yes — verify POST to `/workspace` in server logs |
| ST-Q-MDEV-005 | After MDEV-001 + MDEV-003: both tabs visible in same window | Local shell tab and Soyeht tab both active. Switching between them is instantaneous | P0 | Yes |
| ST-Q-MDEV-006 | In local shell tab: `git log --oneline -3` → select all output (Cmd+A) → copy (Cmd+C) → switch to Soyeht tab → paste (Cmd+V) | Clipboard content from local shell appears in the Soyeht tab's input. Server receives the pasted text | P1 | Assisted |
| ST-Q-MDEV-007 | In Soyeht tab: run `pwd` on server → copy output → switch to local tab → paste | Server path appears in local shell input. Correct `cd` command can be constructed from it | P1 | Assisted |
| ST-Q-MDEV-008 | Open 2 Soyeht tabs (different instances) + 1 local shell tab | All 3 tabs independent. Typing in one does not affect the others. `tput cols` is independent per tab | P1 | Yes |
| ST-Q-MDEV-009 | Close local shell tab (Cmd+W) | Soyeht tab(s) unaffected. Local PTY process gone (`ps aux` check). No reconnect triggered in WS tabs | P1 | Yes |
| ST-Q-MDEV-010 | Close a Soyeht tab (Cmd+W) | Local shell tab unaffected. WS closed cleanly. Other Soyeht tabs unaffected | P1 | Yes |
| ST-Q-MDEV-011 | Instance picker: instance list is empty or fetch fails | Picker shows empty state with retry option. No crash. Other open tabs unaffected | P2 | Yes |

## Cleanup
- Delete `test-qa-mac-ws-*` workspaces from server after test run

## Notes
The clipboard bridge (MDEV-006, MDEV-007) is the primary inter-terminal communication mechanism for v1. There is no direct IPC between tabs — they are independent processes/connections. The user copies from one terminal and pastes into the other via the system clipboard (NSPasteboard). This is intentional and the correct macOS pattern.
