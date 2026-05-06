---
id: mac-window-workspace-identity
ids: ST-Q-MWID-001..017
profile: standard
automation: assisted + unit
requires_device: false
requires_backend: false
destructive: false
cleanup_required: true
platform: macOS
---

# macOS Window / Workspace Identity

## Objective
Verify that each real macOS Soyeht window owns an independent, identifiable workspace/tab set. A second window must not be a mirrored rendering of the first window's workspace model.

## Risk
- New Window reuses the previous window's workspace/pane IDs, causing duplicated visible names and ambiguous MCP routing.
- Closing, deleting, or renaming a workspace in one window mutates another window because both windows point at the same model entity.
- MCP exposes workspaces and panes without their owning `windowID`, forcing agents to route by ambiguous display names.
- Closed windows leave stale ownership behind, making later workspace deletion detach from a non-existent window instead of removing the intended workspace.

## Preconditions
- Soyeht macOS app is running.
- Use Shell > New Window or Cmd+N for real app windows; do not use AppKit tab detaching as a substitute for this domain.
- For MCP cases, discover window IDs with `list_windows` before issuing scoped operations.

## Evidence To Capture
- Screenshot or accessibility snapshot showing two open Soyeht windows.
- MCP JSON output for `list_windows`, `list_workspaces`, and `list_panes`.
- Before/after JSON for rename, close, and move operations.
- The stable identifiers involved: `windowID`, `workspaceID`, `conversationID`, and pane handle.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWID-001 | Open the app, note Window A active workspace and shell IDs, then run Shell > New Window | Window B has a different `windowID`, different active `workspaceID`, and different shell `conversationID`. It does not render Window A's workspace as its own tab. | P0 | Unit + Assisted |
| ST-Q-MWID-002 | With two windows open, list workspaces for each window | Each window-scoped list returns only that window's workspaces. No workspace ID appears in both windows unless deliberately shared by an explicit move/attach flow. | P0 | Unit + Assisted |
| ST-Q-MWID-003 | Rename the active workspace in Window B | Only Window B's workspace title changes. Window A keeps its previous workspace title and ID. | P1 | Assisted |
| ST-Q-MWID-004 | Rename a shell/tab handle in Window B | Only the targeted pane handle changes. Window A panes with similar old display names remain unchanged. | P1 | Assisted |
| ST-Q-MWID-005 | Close/delete a non-last workspace in Window B | The workspace disappears from Window B only. Window A remains open with its own workspace(s), panes, and active selection intact. | P0 | Unit + Assisted |
| ST-Q-MWID-006 | Close Window B entirely, then close a workspace in Window A | Closed Window B is not treated as an owner. Window A workspace teardown follows normal rules and does not leave a phantom workspace because of a stale closed-window mapping. | P1 | Unit |
| ST-Q-MWID-007 | Create multiple workspaces/shells in Window A, then create a new Window B | Newly generated visible names are globally unique or otherwise unambiguous. Counters do not reset in a way that creates two indistinguishable "Workspace 2" / "Shell 2" targets. | P1 | Unit + Assisted |
| ST-Q-MWID-008 | Reorder workspaces in Window A | Window A tab order changes. Window B tab order is unchanged. | P2 | Unit |
| ST-Q-MWID-009 | Use MCP `list_windows` with two windows open | Response includes both open windows, unique `windowID` values, active workspace IDs, visible titles, and nested workspace summaries with pane counts. | P0 | Assisted |
| ST-Q-MWID-010 | Use MCP `list_workspaces` and `list_panes` with each `windowID` | Results are scoped to the requested window and each returned workspace/pane includes its owning `windowID`. | P0 | Assisted |
| ST-Q-MWID-011 | From Window A's context, send input to a pane in Window B by `targetWindowID` + `conversationID` | Only the Window B pane receives input. Window A panes do not receive or echo the payload. | P0 | Assisted |
| ST-Q-MWID-012 | Move a pane from Window A to a destination workspace in Window B using `destinationWindowID` + destination workspace ID | The pane appears in the intended Window B workspace; source workspace updates correctly; no name-based ambiguous routing is needed. | P0 | Assisted |
| ST-Q-MWID-013 | Rename a workspace to an existing workspace name | Rename is rejected with a visible "name already exists" message. After OK, the rename prompt reopens with the attempted name still filled. The workspace keeps its old name; no automatic suffix is applied. | P1 | Unit + Assisted |
| ST-Q-MWID-014 | Rename a shell/pane handle to an existing handle | Rename is rejected with a visible "name already exists" message. After OK, the rename prompt reopens with the attempted handle still filled. The pane keeps its old handle; no automatic suffix is applied. | P1 | Unit + Assisted |
| ST-Q-MWID-015 | Use MCP with `targetWindowID` for Window B but a `conversationID` from Window A | Tool rejects the request. It must not mutate Window A while reporting Window B in the response. | P0 | Assisted |
| ST-Q-MWID-016 | Quit/relaunch with two Windows that have distinct workspace membership | Restored Windows reopen with their original `windowID`, active workspace, and membership/order via snapshot v4 window sessions. A new non-restored Window can still start from the global inventory. | P1 | Unit + Assisted |
| ST-Q-MWID-017 | Share workspace W between Window A and B, then move W's last pane to another workspace/window | Every open window that previously pointed at W ends on a valid active workspace; no tab, active context, or container points at the removed workspace. | P1 | Unit + Assisted |

## Manual Execution Notes

1. Start from a clean enough session with one Soyeht main window open.
2. Use Shell > New Window or Cmd+N to create the second real window.
3. Run `list_windows` and record both `windowID` values.
4. Run `list_workspaces` and `list_panes` once for each `windowID`.
5. Perform rename, close, and move operations using IDs, not visible names.
6. Re-run the list commands and compare IDs, pane counts, active workspace, and visible names.

## Acceptance
- No operation relies on a display name when a stable ID is available.
- User-visible names are not ambiguous across open windows.
- Window-scoped list/rename/close/reorder operations never mutate another open window's workspace membership by accident.
- Window-scoped pane operations reject pane IDs/handles outside the target window.
- Snapshot v4 persists Window-to-workspace membership and window sessions so relaunch/restoration does not collapse independent windows into one workspace list.
- MCP can route a request to another open window by `windowID`, then to a workspace by `workspaceID`, then to a pane by `conversationID` or handle.
