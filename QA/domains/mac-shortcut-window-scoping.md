---
id: mac-shortcut-window-scoping
ids: ST-Q-MSCOP-001..004
profile: standard
automation: unit + assisted
requires_device: false
requires_backend: false
destructive: false
cleanup_required: true
platform: macOS
---

# macOS Shortcut Window Scoping

## Objective
Verify mutable macOS menu and keyboard commands act only on the current UI
target window. Two Soyeht windows with different panes must never cross-mutate
focus, pane layout, workspace selection, or undo state because a shortcut used a
stale global fallback.

## Permanent Coverage
- `ShortcutArchitectureBaselineTests` protects the shortcut single source of
  truth and blocks public UI command paths from using automation/headless window
  fallbacks.
- `AppCommandRoutingPresentationTests.testPaneFocusShortcutRegressionMutatesOnlyCurrentUIWindowTarget`
  is the CI-safe two-window regression for Command+Shift+Left/Right. It resolves
  shortcuts through `AppCommandShortcutRouter`, dispatches through
  `AppCommandActionRouter`, and asserts only the current UI target changes.

## Local Smoke Preconditions
1. Build and launch a Soyeht Dev app from the branch under test.
2. Use isolated runtime state:
   - `SOYEHT_AUTOMATION_DIR=/tmp/soyeht-shortcut-window-scope`
   - `SOYEHT_WORKSPACE_STORE_URL=file:///tmp/soyeht-shortcut-window-scope/workspaces.json`
3. Open two real Soyeht windows with Shell > New Window or Command+N.
4. In each window, create at least two panes so left/right focus changes are
   observable. Record each window's `windowID`, active workspace, pane IDs, and
   `activePaneID` via LLDB or Soyeht automation.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MSCOP-001 | With Window A key and Window B visible, press Command+Shift+Right | Only Window A's active pane/focus changes. Window B's `activePaneID`, workspace, and panes are unchanged. | P0 | Unit + Assisted |
| ST-Q-MSCOP-002 | Make Window B key, press Command+Shift+Right | Only Window B's active pane/focus changes. Window A stays at its previous state. | P0 | Unit + Assisted |
| ST-Q-MSCOP-003 | Make Window A key again, press Command+Shift+Left | Only Window A's active pane/focus changes. Window B stays at its previous state. | P0 | Unit + Assisted |
| ST-Q-MSCOP-004 | Repeat with Option+Shift+Left/Right, split pane, close pane, and workspace move shortcuts if the branch touches command routing | Each command mutates only the current key/main Soyeht window. Automation/headless fallback is not used for public UI shortcuts. | P1 | Assisted |

## Evidence To Capture
- Before/after `windowID`, active workspace ID, and `activePaneID` for both windows.
- The exact shortcut pressed and which window was key.
- If LLDB is used, capture the expression output showing each controller's active
  workspace and pane state before and after each shortcut.

## Acceptance
- Public UI commands resolve their target from the UI scope only:
  key window or sheet owner first, then main window or sheet owner, then nil.
- `NSApp.orderedWindows.first`, `mainWindowControllers.first`, and
  `activeMainWindowController` do not appear in public mutable shortcut/menu
  paths.
- Automation/headless fallback remains explicit and separate from UI command
  routing.
