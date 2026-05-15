# Paired Macs Flow — 2026-04-18

Validation run for Fase 2 closeout (branch `feat/qrcode`). Primary goals:
close the pending items from the original plan and prove H4 (session
persistence across background) end-to-end on device.

## Environment

- **iPhone <qa-device-2>** (iPhone 13 mini, UDID `<ios-udid>`)
- **Mac app**: `Soyeht` built from `feat/qrcode` with Fase 1 + Fase 2 + the
  attach-nonce refresh fix (commit `4983fb6`)
- **Runner**: `QA/scripts/run_paired_macs.py` via `uv run`
- **Presence transport**: LAN / Tailscale — no backend involved

## Auto cases

| ID | Case | Status |
|----|------|--------|
| PM-001 | Home list renders Mac row with `[mac]` tag in <15 s | PASS |
| PM-002 | Tap Mac row → MacDetailView with pane list | PASS |
| PM-003 | Tap pane → terminal opens via attach (no QR) | PASS |
| PM-013 | Background 8 s → foreground → same terminal restored with scrollback | PASS |
| PM-006 | Terminate + relaunch app → home reconnects | PASS |

Full runner summary (final execution):
`{'PASS': 5, 'FAIL': 0, 'SKIP': 0}`

## H4 regression check — multi-cycle

PM-013 was executed **three times back-to-back** after the fix:

1. First cycle after setup (PM-001..PM-003) — PASS, no `[WS] Reconnecting…`
   banner in the scrollback.
2. Second cycle (runner re-invoked with `--only PM-013`) — PASS, scrollback
   still intact.
3. Third cycle — PASS, terminal restored silently.

The refresher pulls a fresh single-use attach nonce from the presence WS
before each reconnect, so `PaneAttachRegistry.consume` succeeds on the first
attempt of every cycle. No retry loop is observed. See
[pm-013-background-foreground.png](pm-013-background-foreground.png) —
scrollback preserved (`zqa-21053` sentinel + Mac shell prompts), no
reconnect chrome.

## Evidence

- [pm-003-terminal-open.png](pm-003-terminal-open.png) — PM-003 reached
  terminal view (`@shell [mac local]`) with Mac scrollback replayed (full
  shell history visible).
- [pm-013-background-foreground.png](pm-013-background-foreground.png) —
  PM-013 after three consecutive background/foreground cycles: same
  terminal, same scrollback, no `[WS] Reconnecting` noise.

## Assisted cases (SKIP in this run)

PM-007..PM-012 need Mac-side orchestration (pkill, `Open on iPhone` button,
rename display name, revoke, local-bash `exit`). They are listed in the
domain spec; runner currently stubs them as SKIP with descriptions.
Follow-up: wire native-devtools MCP / AppleScript helpers into the runner.

## Commits validated

- `0c36693` — chore(tests): remove orphan SoyehtAPIClientTests case
- `f03da39` — feat(pairing): H12 pane status transitions
- `a2191f7` — test(pairing): PaneAttachRegistry unit coverage via SPM
- `4983fb6` — fix(pairing): refresh attach nonce on reconnect (H4)
- `c07d50d` — qa(automation): paired-macs-flow runner + PM-013
