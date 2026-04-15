---
id: mac-tab-management
ids: ST-Q-MTAB-001..010
profile: quick
automation: assisted
requires_device: false
requires_backend: false
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Tab Management

## Objective
Verify native macOS window tab behavior: creating/closing tabs, keyboard navigation, drag-to-detach, Merge All Windows, and mixed tab types (local shell + Soyeht instance) in the same tab group.

## Risk
- `tabbingIdentifier` not set on both `LocalShellWindowController` and `SoyehtTerminalWindowController` → new windows open as separate windows instead of tabs
- `newWindowForTab(_:)` not overridden → macOS tab bar "+" button does nothing or crashes
- Tab group ordering breaks after drag-to-detach + merge cycle

## Preconditions
- macOS app running, logged in (at least one server paired)
- At least one Soyeht instance online

## How to automate
- **Open new tab**: `mcp__XcodeBuildMCP__key_press` for Cmd+T
- **Close tab**: Cmd+W
- **Navigate tabs**: Cmd+Shift+[ and Cmd+Shift+]
- **Verify tab count**: `mcp__XcodeBuildMCP__snapshot_ui` or `mcp__XcodeBuildMCP__screenshot` + count tab titles in accessibility tree
- **Drag-to-detach**: Manual (macOS window drag — not scriptable via XcodeBuildMCP)

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MTAB-001 | Press Cmd+T | New local shell tab opens inside the same window. Tab bar visible with 2 tabs | P0 | Yes |
| ST-Q-MTAB-002 | Press Cmd+T three times → 4 tabs total | All 4 tabs visible in tab bar. Each has its own shell prompt | P1 | Yes |
| ST-Q-MTAB-003 | Press Cmd+W on active tab | Active tab closes. Adjacent tab gains focus. Other tabs unaffected | P0 | Yes |
| ST-Q-MTAB-004 | Open a Soyeht instance via instance picker | Soyeht tab opens in the same window tab group. Tab title = instance name | P0 | Yes |
| ST-Q-MTAB-005 | Local shell tab + Soyeht tab in same window | Both tabs functional. Switching between them is instant. Each maintains independent session | P0 | Yes |
| ST-Q-MTAB-006 | Press Cmd+Shift+[ and Cmd+Shift+] | Focus cycles through tabs in order. Correct tab becomes active | P1 | Yes |
| ST-Q-MTAB-007 | Drag a tab out of the window tab bar | Tab detaches into its own standalone window. Session continues (no reconnect) | P1 | Manual |
| ST-Q-MTAB-008 | After MTAB-007: Window > Merge All Windows | Detached window rejoins tab group. Session continues in merged tab | P1 | Manual |
| ST-Q-MTAB-009 | Press Cmd+W on the last remaining tab | Window closes. App stays running (Dock icon remains). No crash | P1 | Yes |
| ST-Q-MTAB-010 | Click "+" button in native tab bar | New local shell tab opens (same behavior as Cmd+T) | P1 | Yes |

## Notes
- Tab persistence across restarts is out of scope for v1 (macOS State Restoration not planned)
- "New Local Shell" vs "New Soyeht Tab" choice is exposed via the toolbar "+" menu item (see mac-dev-workflow.md for picker tests)
