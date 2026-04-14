# QA Report: Scrollback Panel Pane Sync Fix Re-Test
**Date:** 2026-04-14
**Tester:** Automated via Appium on real device
**Device:** iPhone <qa-device> (iOS 26.4.1, UDID: <ios-udid>)
**App:** `com.soyeht.app` (Debug build installed after active-pane sync fix)
**Instance:** `caio` `[hermes-agent]`
**Scope:** Re-test `ST-Q-SCRL-002`, `ST-Q-SCRL-003`, plus smoke for legacy `ST-Q-TMUX-009`

> Update 2026-04-14 16:50 - superseded by a clean-build rerun after explicit
> `devicectl` install. Latest real-device result on the same iPhone:
> `ST-Q-SCRL-002 PASS`, `ST-Q-SCRL-003 PASS`, `ST-Q-TMUX-009 PASS`.

---

## Executive Summary

**3 checks executed: 1 PASS, 2 FAIL.**

The new build installs and runs correctly on the real device, but the active-pane sync fix did **not** resolve the floating scrollback issue on hardware.

The reproduced behavior is unchanged from the previous real-device run:

- with the floating panel closed, pane switching works normally;
- with the floating panel open, switching panes changes the live terminal behind the panel;
- the panel history itself remains stuck on the previously active pane.

The legacy history button / capture-pane viewer still works.

## Results

| ID | Check | Result | Notes |
|----|-------|--------|-------|
| ST-Q-SCRL-002 | With panel open, tap a different pane tab | FAIL | Starting from pane `1:bash`, tapping `0:node` moved the active tab and the live terminal behind the panel, but the panel continued to show `paneone414` / `-bash: paneone414: command not found`. |
| ST-Q-SCRL-003 | With panel open, swipe on the live terminal area below the panel | FAIL | Starting from pane `1:bash`, swiping right on the visible live-terminal strip switched the live terminal to `0:node`, but the panel continued to show `paneone414` / `-bash: paneone414: command not found`. |
| ST-Q-TMUX-009 | Legacy history button / capture-pane viewer smoke | PASS | The bottom `history` button still opened the legacy capture-pane viewer in `pager` mode. |

## Evidence

| File | Purpose |
|------|---------|
| `baseline-pane1-no-panel.png` | Baseline: pane `1:bash` selected with the floating panel closed. |
| `panel-open-pane1.png` | Floating panel opened from pane `1:bash`, showing correct initial `paneone414` history. |
| `panel-open-after-tab0.png` | After tapping tab `0:node` with the panel open, mixed state is visible on screen. |
| `panel-open-after-tab0.xml` | Accessibility dump confirming `paneone414` remains present after the tab switch. |
| `panel-open-after-swipe.png` | After swiping to pane `0:node` with the panel open, mixed state remains visible. |
| `panel-open-after-swipe.xml` | Accessibility dump confirming `paneone414` remains present after the swipe. |
| `legacy-history-button.png` | Legacy `history` button still opens the capture-pane viewer. |

## Finding

### SCRL-REAL-002: Active-pane sync fix does not update floating panel on real device

**Severity:** High

The newly added active-pane-change notification path did not change the observable behavior on the physical iPhone. The floating panel still renders the previous pane's history after a successful pane switch, for both:

- tab tap switching
- live-terminal swipe switching

This means the branch still fails the central requirement behind `ST-Q-SCRL-002` and `ST-Q-SCRL-003`.

## Not Executed

- `ST-Q-SCRL-004`
- `ST-Q-SCRL-005`
- `ST-Q-SCRL-006`
- `ST-Q-SCRL-007`

Those remain deferred because the core pane-sync behavior is still failing on the real device.

---

## Latest Clean-Build Rerun

**Date:** 2026-04-14
**Build install method:** `xcrun devicectl device install app --device <ios-udid> .../Debug-iphoneos/Soyeht.app`
**Panel markers used:** pane `1:bash` contained `paneone414`; pane `0:node` contained the long `auth.openai.com` output / pane-zero history.

### Final Results

| ID | Check | Result | Notes |
|----|-------|--------|-------|
| ST-Q-SCRL-002 | With panel open, tap a different pane tab | PASS | Starting from pane `1:bash`, tapping `0:node` switched the panel from the `paneone414` history to pane `0` history immediately. |
| ST-Q-SCRL-003 | With panel open, swipe on the live terminal area below the panel | PASS | Starting from pane `0:node`, swiping left on the visible live-terminal strip switched the panel back to pane `1:bash`, restoring the `paneone414` history. |
| ST-Q-TMUX-009 | Legacy history button / capture-pane viewer smoke | PASS | The bottom `history` button still opened the legacy capture-pane viewer. |

### Notes

- The tab-switch path is now updating the floating scrollback to the correct pane on the physical device.
- The swipe path is also updating the floating scrollback, using the same panel instance while the live terminal changes underneath.
- The earlier failure in this file should be treated as historical context only; the latest clean-build rerun is the current verdict.
