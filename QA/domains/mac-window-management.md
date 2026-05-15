---
id: mac-window-management
ids: ST-Q-MWIN-001..007
profile: standard
automation: assisted
requires_device: false
requires_backend: false
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Window Management

## Objective
Verify macOS-native window behaviors: detach-to-window, Merge All Windows, terminal title escape sequences updating tab title, resize preservation per-tab, and correct app lifecycle (app stays alive after last tab closes).

## Risk
- `tabbingIdentifier` mismatch after detach → detached window doesn't rejoin tab group on Merge
- Terminal title escape sequence (`\033]0;...\007`) not connected to `view.window?.title` in `LocalShellWindowController` or `SoyehtInstanceViewController`
- Column/row count not per-tab → resizing one tab corrupts the column count in another
- `applicationShouldTerminateAfterLastWindowClosed` returning `true` → app quits when last tab is closed (wrong for a terminal app)

## Preconditions
- macOS app running with at least one tab open

## How to automate
- **Screenshot + UI snapshot**: `mcp__XcodeBuildMCP__screenshot`, `snapshot_ui`
- **Type escape sequences**: `mcp__XcodeBuildMCP__type_text` (raw escape sequences require `key_sequence`)
- **Verify title**: `snapshot_ui` → read `NSWindow.title` from accessibility tree
- **Drag-to-detach / Merge All Windows**: Manual (window drag and menu item — not scriptable via XcodeBuildMCP)

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWIN-001 | Drag a tab out of the tab bar to an empty area of the screen | Tab detaches into a standalone window. Terminal session continues without reconnect | P1 | Manual |
| ST-Q-MWIN-002 | After MWIN-001: Window > Merge All Windows (menu) | Detached window re-joins the original tab group. Tab order is preserved. Session continues | P1 | Manual |
| ST-Q-MWIN-003 | In local shell tab: `printf '\033]0;MyRepoTitle\007'` | macOS tab title and window title update to "MyRepoTitle" within 1 second | P2 | Yes |
| ST-Q-MWIN-004 | Open 2 tabs; resize window to wide (200 cols); switch between tabs | All tabs share the same window frame — both tabs show 200 cols. `tput cols` in both tabs equals the current window width. This is correct macOS tab behavior (`addTabbedWindow` shares the frame) | P1 | Assisted |
| ST-Q-MWIN-005 | Close last tab via Cmd+W | Window closes. App **stays running** (Dock icon present). No crash. New Cmd+N or Cmd+T opens a fresh window | P0 | Yes |
| ST-Q-MWIN-006 | Two separate windows (each with their own tab group): close one window entirely | Remaining window and its sessions unaffected. App stays running | P1 | Yes |
| ST-Q-MWIN-007 | Zoom window (green traffic light) in full-screen mode | Terminal fills screen. Column/row count updates. Exiting full-screen restores previous size | P2 | Assisted |

## Notes
- MWIN-004 clarification: each tab's terminal dimensions are owned by the PTY/WebSocket connection for that tab. The window frame is shared but each tab tracks its own last-known size independently. When you switch to a tab, its view fills the window and reports the current frame size to its connection.
- Terminal title from escape sequence (MWIN-003) applies to both local shell and Soyeht tabs. For Soyeht tabs, the server may also send title updates via the `setTerminalTitle` delegate method — both paths should work.
