# QA Gate Report — Full
**Date:** 2026-04-16 15:52:47
**Level:** full
**Repository:** `~/Documents/SwiftProjects/iSoyehtTerm`
**Git:** `main` @ `02a58c9`

## Verdict: PASS WITH FOLLOW-UPS

## Phase Results

| Phase | Status | Required | Command | Log | Notes |
| --- | --- | --- | --- | --- | --- |
| iOS Unit Tests | PASS | yes | `make test` | logs/ios-tests.log |  |
| SwiftPM Tests | PASS | yes | `make test-spm` | logs/spm-tests.log |  |
| Contract Smoke | PASS | yes | `bash ~/Documents/SwiftProjects/iSoyehtTerm/QA/contract-smoke.sh https://<host>.<tailnet>.ts.net` | logs/contract-smoke.log |  |
| Standard Gate Smoke | PASS | yes | `python3 ~/Documents/SwiftProjects/iSoyehtTerm/QA/scripts/run_smoke_appium.py` | logs/standard-smoke.log |  |
| Full Critical Suites | PASS | yes | `python3 ~/Documents/SwiftProjects/iSoyehtTerm/QA/scripts/run_full_gate.py` | logs/full-suites.log |  |

## Domain Coverage

| Automation | Count |
| --- | --- |
| assisted | 15 |
| auto | 8 |

## Assisted / Manual Follow-Ups

- Scrollback Panel (ST-Q-SCRL-001..007) — assisted, profile `standard` — `domains/scrollback-panel.md`
- Deep Links (ST-Q-DEEP-001..011) — assisted, profile `full` — `domains/deep-links.md`
- Multi-Server (ST-Q-MSRV-001..012) — assisted, profile `full` — `domains/multi-server.md`
- WebSocket Recovery (ST-Q-WSRC-001..010) — assisted, profile `full` — `domains/websocket-recovery.md`
- Attachments & Permissions (ST-Q-ATCH-001..014) — assisted, profile `full` — `domains/attachments-permissions.md`
- File Browser (ST-Q-BROW-001..025) — assisted, profile `full` — `domains/file-browser.md`
- Settings Live (ST-Q-SETS-001..007) — assisted, profile `full` — `domains/settings-live.md`
- Error Handling (ST-Q-ERR-001..004) — assisted, profile `standard` — `domains/error-handling.md`
- macOS Auth & Session (ST-Q-MAUTH-001..007) — assisted, profile `quick` — `domains/mac-auth.md`
- macOS Tab Management (ST-Q-MTAB-001..010) — assisted, profile `quick` — `domains/mac-tab-management.md`
- macOS Local Shell (ST-Q-MLSH-001..007) — assisted, profile `quick` — `domains/mac-local-shell.md`
- macOS Soyeht Terminal (ST-Q-MWST-001..009) — assisted, profile `quick` — `domains/mac-soyeht-terminal.md`
- macOS Dev Workflow (ST-Q-MDEV-001..011) — assisted, profile `standard` — `domains/mac-dev-workflow.md`
- macOS ↔ iOS Cross-Device (ST-Q-MXDEV-001..010) — assisted, profile `full` — `domains/mac-cross-device.md`
- macOS Window Management (ST-Q-MWIN-001..007) — assisted, profile `standard` — `domains/mac-window-management.md`
