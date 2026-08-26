# QA Gate Report — Quick
**Date:** 2026-08-24 23:46:01
**Level:** quick
**Repository:** `/Users/macstudio/soyeht-worktrees/iSoyehtTerm/manual-pane-mcp-auth`
**Git:** `feat/manual-pane-mcp-auth` @ `2918120c`

## Verdict: PASS WITH FOLLOW-UPS

## Phase Results

| Phase | Status | Required | Command | Log | Notes |
| --- | --- | --- | --- | --- | --- |
| iOS Unit Tests | PASS | yes | `make test` | logs/ios-tests.log |  |
| SwiftPM Tests | PASS | yes | `make test-spm` | logs/spm-tests.log |  |
| Contract Smoke | PASS | yes | `bash /Users/macstudio/soyeht-worktrees/iSoyehtTerm/manual-pane-mcp-auth/QA/contract-smoke.sh http://localhost:8892` | logs/contract-smoke.log |  |

## Domain Coverage

| Automation | Count |
| --- | --- |
| assisted | 4 |
| auto | 5 |

## Assisted / Manual Follow-Ups

- macOS Auth & Session (ST-Q-MAUTH-001..007) — assisted, profile `quick` — `domains/mac-auth.md`
- macOS Tab Management (ST-Q-MTAB-001..010) — assisted, profile `quick` — `domains/mac-tab-management.md`
- macOS Local Shell (ST-Q-MLSH-001..007) — assisted, profile `quick` — `domains/mac-local-shell.md`
- macOS Soyeht Terminal (ST-Q-MWST-001..009) — assisted, profile `quick` — `domains/mac-soyeht-terminal.md`
