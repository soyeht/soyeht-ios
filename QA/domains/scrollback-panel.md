---
id: scrollback-panel
ids: ST-Q-SCRL-001..007
profile: standard
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Scrollback Panel & Active Pane Sync

## Objective
Verify that the floating scrollback panel introduced by the split-history work stays aligned with the currently active tmux pane while the user switches panes via tabs or live-terminal swipes, and that it refreshes correctly across reopen, font-size changes, and terminal recreation.

This plan covers only the floating scrollback panel. The existing history button / capture-pane viewer remains covered by `ST-Q-TMUX-009`.

## Risk
If active pane changes do not trigger a fresh history fetch, the panel can show stale or mixed history from the previously selected pane. If the host recreates the terminal without detaching the old panel, duplicate overlays or dead observers can remain on-screen. If font-size changes do not reload the panel, row height and text rendering drift out of sync.

## Preconditions
- Connected to an instance with an active tmux session
- Session has at least 2 panes with distinct marker text already emitted in each pane
- Recommended marker setup: `PANE-A-MARKER`, `PANE-B-MARKER`, and one long line in each pane for horizontal interaction checks
- History handle is visible at the top of the terminal host

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCRL-001 | Drag down the scrollback handle to open the panel | Panel expands smoothly, latest history for the current pane is visible, and no visual seam/crash appears | P1 | Assisted |
| ST-Q-SCRL-002 | With the panel open, tap a different pane tab | Active pane changes and the panel refreshes to the tapped pane. The new pane marker is visible and the previous pane marker is not shown in the refreshed tail | P1 | Assisted |
| ST-Q-SCRL-003 | With the panel open, swipe left/right on the live terminal area below the panel | Pane changes exactly as it does with the panel closed, and the panel updates to the newly active pane's history | P1 | Assisted |
| ST-Q-SCRL-004 | With the panel open, switch panes rapidly multiple times (tabs and/or swipes) | Final selected pane wins, panel shows only that pane's history, and there is no duplicate fetch artifact or crash | P1 | Assisted |
| ST-Q-SCRL-005 | Collapse the panel, emit fresh output in the current pane, then reopen it | Reopened panel shows the latest output for the current pane only, with no stale snapshot from the previous open | P2 | Assisted |
| ST-Q-SCRL-006 | Change font size while the panel is open | Scrollback rows re-render at the new font size, text is not clipped, and the panel still shows the current pane's history | P2 | Assisted |
| ST-Q-SCRL-007 | Reconnect or recreate the terminal after the panel has been used | Exactly one scrollback panel exists after reconnect, opening it still works, and it follows the currently active pane's history | P1 | Assisted |

## Execution Notes
- For ST-Q-SCRL-003, start the gesture on the live terminal area below the expanded panel, not on the panel collection view itself.
- After every pane switch, validate both sides of the contract: the selected pane marker must appear, and the previously active pane marker must not remain in the visible tail.
- If the session has more than 2 panes, verify both swipe directions at least once.

## Related Runs
- [2026-04-14 Scrollback Panel Real Device Final](../runs/2026-04-14-scrollback-panel-real-device-final/report.md) — final physical-device closure for the branch, including real-device `xcodebuild test`, floating-panel sync, reopen, font-size, reconnect, and legacy history-button smoke.
- [2026-04-14 Scrollback Panel Real Device Fix Re-Test](../runs/2026-04-14-scrollback-panel-real-device-fix/report.md) — re-test on physical hardware after the active-pane sync notification fix; panel still stayed on the previous pane for tab and swipe switching.
- [2026-04-14 Scrollback Panel Real Device](../runs/2026-04-14-scrollback-panel-real-device/report.md) — physical-device validation of floating-panel pane sync and legacy history-button smoke coverage.
- [2026-04-06 History View](../runs/2026-04-06-history-view/report.md) — legacy history overlay regression run that previously confirmed stale-content and swipe-propagation bugs across pane switches.
