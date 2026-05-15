# QA Report: Scrollback Panel Pane Sync on Real Device
**Date:** 2026-04-14
**Tester:** Automated via Appium on real device
**Device:** iPhone <qa-device> (iOS 26.4.1, UDID: <ios-udid>)
**App:** `com.soyeht.app` (Debug build)
**Instance:** `caio` `[hermes-agent]`
**Scope:** `ST-Q-SCRL-001..003` and smoke check for `ST-Q-TMUX-009`

---

## Executive Summary

**4 checks executed: 2 PASS, 2 FAIL.**

The new floating scrollback panel opens correctly and hydrates the active pane's history on first open. The legacy history button / capture-pane viewer also still opens correctly on the real device.

The pane-sync contract is currently broken once the floating panel is already open. Both pane-switch vectors requested for this branch were reproduced on the real phone:

- Tapping a different tmux tab changes the live terminal behind the panel.
- Swiping on the live terminal strip below the panel also changes the live terminal.
- In both cases, the panel history stays on the previous pane until the panel is closed and reopened.

That means the branch is **not ready to close** from a QA perspective.

## Results

| ID | Check | Result | Notes |
|----|-------|--------|-------|
| ST-Q-SCRL-001 | Open floating scrollback panel | PASS | From pane `1:bash`, the panel opened and exposed `paneone414` / `-bash: paneone414: command not found`, confirming correct initial hydration for the active pane. |
| ST-Q-SCRL-002 | With panel open, tap a different pane tab | FAIL | Starting from pane `1:bash`, tapping tab `0:node` changed the live terminal to Codex, but the panel collection view still exposed `paneone414` history from `1:bash`. |
| ST-Q-SCRL-003 | With panel open, swipe on the live terminal area below the panel | FAIL | Starting from pane `1:bash`, swiping right on the visible live-terminal strip below the panel changed the live terminal to `0:node`, but the panel collection view still exposed `paneone414` history from `1:bash`. |
| ST-Q-TMUX-009 | Legacy history button / capture-pane viewer smoke | PASS | Tapping the bottom `history` button still opened the existing capture-pane viewer in `pager` mode on the real device. |

## Evidence

| File | Purpose |
|------|---------|
| `tab-switch-no-panel-pane1.png` | Baseline that pane switching works normally with the floating panel closed. |
| `panel-open-tap-tab0.png` | Panel-open tab-switch scenario showing mixed state after tapping `0:node`. |
| `panel-open-tap-tab0.xml` | Accessibility source proving the panel still exposed `paneone414` after the tab switch. |
| `panel-open-swipe-to-pane0.png` | Panel-open swipe scenario showing the lower live terminal strip moved to `0:node`. |
| `panel-open-swipe-to-pane0.xml` | Accessibility source proving the panel still exposed `paneone414` after the swipe. |
| `after-swipe-close-panel.png` | After closing the panel, the live terminal is fully on `0:node`, confirming the swipe did switch panes. |
| `legacy-history-button.png` | Smoke evidence that the old history button still opens the capture-pane viewer. |

## Findings

### SCRL-REAL-001: Floating panel does not refresh after pane switch

**Severity:** High
**Applies to:** `ST-Q-SCRL-002`, `ST-Q-SCRL-003`

**Repro path 1**

1. Open tmux pane `1:bash`.
2. Open the floating scrollback panel.
3. Confirm the panel shows `paneone414`.
4. Tap tmux tab `0:node`.

**Actual**

- The live terminal switches to `0:node`.
- The panel continues rendering the old `1:bash` history.

**Repro path 2**

1. Open tmux pane `1:bash`.
2. Open the floating scrollback panel.
3. Swipe right on the visible live-terminal strip below the panel.

**Actual**

- The live terminal switches to `0:node`.
- The panel continues rendering the old `1:bash` history.

**Expected**

- The floating panel should immediately re-fetch and display the history for the newly active pane.
- The previous pane marker should disappear from the visible tail.

## Not Executed

- `ST-Q-SCRL-004` rapid switching
- `ST-Q-SCRL-005` collapse, emit fresh output, reopen
- `ST-Q-SCRL-006` font-size change
- `ST-Q-SCRL-007` terminal recreation / reconnect

Those were deferred because the core pane-sync requirement already failed on the physical device.
