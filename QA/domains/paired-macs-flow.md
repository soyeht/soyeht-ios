---
id: paired-macs-flow
ids: ST-Q-PM-001..012
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Paired Macs — Fase 2 presence + attach + open-on-iPhone + status

## Objective
Verify the Fase 2 "Mac as home entity" feature works end-to-end:
- Paired Macs appear on the iPhone home list alongside claws, with `[mac]` tag
and an `🖥` icon.
- Tap a Mac → MacDetailView lists live panes with agent icon + status dot.
- Tap a pane → terminal opens via `/panes/<id>/attach`, scrollback replays,
no QR required.
- Mac app pushes `open_pane_request` via presence WS; iPhone foreground
auto-navigates.
- Presence reconnects with exponential backoff after brief network drops.
- Status dots flip between `active`/`mirror` (green), `idle` (yellow),
`dead` (red), `offline` (gray) as expected.

## Risk
- Port migration: iPhones paired pre-Fase 2 don't have `presence_port` /
`attach_port` in storage. They receive them on next `local_handoff_ready`.
If the migration code regresses, paired iPhones stay permanently `offline`.
- `setClientRequestHandler` path detection: if Apple's API changes this
shape, path dispatch breaks for both presence and attach listeners.
- Race between NSAlert TOFU (Fase 1) and presence WS autoconnect: if
`PairedMacRegistry` bootstraps before pair flow persists, we may attempt
a presence connection with a wrong (0) port.

## Preconditions
- Mac app running with Fase 2 build, ports logged in `com.soyeht.mac:presence`
subsystem.
- iPhone paired via Fase 1 QR (pair_accept has sent `presence_port` +
`attach_port`).
- Both devices reachable over Wi-Fi, Tailscale, or LAN. No restriction on
same subnet.

## How to generate test state
- **Fresh pair**: `soyeht pair` output scan generates new `device_id` on iOS.
Mac pair_accept includes ports, iPhone persists them.
- **Migrated pair**: iPhone already paired (from Fase 1). Next resume flow
piggyback ports via `local_handoff_ready`.
- **Pane creation**: click agent button in any Mac pane cell (bash/claude/
codex/hermes). PaneStatusTracker fires delta.
- **Simulated offline**: pkill Soyeht.app on Mac. iPhone presence WS closes,
MacHomeRow status → `offline (...)`.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-PM-001 | App iOS abre com Mac pareado (Fase 2). Home list renders | Mac row shows `[mac]` tag, `🖥` icon, dot yellow (connecting) → green (online) in <3s | P0 | Yes — launch + screenshot |
| ST-Q-PM-002 | Tap Mac row | MacDetailView sheet opens showing list of panes (empty or populated) | P0 | Yes |
| ST-Q-PM-003 | Click a pane in MacDetailView (ex `@shell`) | Terminal opens with PTY binary stream, scrollback replay visible, no QR | P0 | Yes |
| ST-Q-PM-004 | Type `ls`, press enter | Mac receives input, output echoes back on iPhone | P0 | Yes |
| ST-Q-PM-005 | Back out of terminal, re-enter same pane | State preserved (no re-handshake visible). Scrollback restored | P1 | Yes |
| ST-Q-PM-006 | Terminate app iOS, relaunch | Home list re-renders, Mac reconnects to `online` in <3s | P1 | Yes |
| ST-Q-PM-007 | Kill Mac app (pkill), observe iPhone for 10s | Home list row becomes `offline (...)` with gray dot. Bring Mac back → `online` in <5s | P1 | Yes |
| ST-Q-PM-008 | Mac creates new pane (click agent) | iPhone receives `panes_delta added=1`, new row in MacDetailView | P0 | Yes — observe via sheet open |
| ST-Q-PM-009 | Mac clicks "Abrir no iPhone" button on a pane | iPhone auto-navigates to that pane within 1s | P1 | Yes — use System Events on Mac to click button |
| ST-Q-PM-010 | Mac changes display name in Preferences, tab out | iPhone home list label updates within 5s | P2 | Yes |
| ST-Q-PM-011 | Mac revokes iPhone in "Dispositivos pareados" panel | Presence WS drops on iPhone, Mac disappears from home list | P1 | Yes |
| ST-Q-PM-012 | Kill local bash pane on Mac (type `exit`) | iPhone sees dot go red (dead) with exit code | P2 | Yes |

## Manual/assisted cases

| ID | Scenario | Expected |
|----|----------|----------|
| ST-Q-PM-MA-01 | 2 iPhones paired to same Mac, both presence-connected | Both see same panes list synchronously. Creating a pane on Mac broadcasts to both within 500ms |
| ST-Q-PM-MA-02 | Switch iPhone between Wi-Fi and Tailscale-only (simulate home → coffee shop) | Presence reconnects via Tailscale CGNAT host in <10s |
| ST-Q-PM-MA-03 | Open+close a pane 20× from iPhone | No WS leak on Mac (`netstat -an \| grep <attach_port>` drops to zero after) |
| ST-Q-PM-MA-04 | 3 iPhones + 15 panes active | Each new pane delta reaches all iPhones in <500ms. Binary PTY throughput not degraded |

## Scripts (next step)

A Python runner under `QA/scripts/run_paired_macs.py` would:
1. `appium_deep_link` with a theyos:// URL (resume or pair).
2. Screenshot home, verify Mac row visible with correct tag.
3. Tap Mac row, screenshot sheet.
4. Tap pane, verify terminal.
5. Run smoke: `ls` → assert output echoed.
6. Back out, re-enter, verify state.

Add to `standard` gate in `QA/INDEX.md` once the script lands.
