---
id: mac-cross-device
ids: ST-Q-MXDEV-001..010
profile: full
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
platform: macOS + iOS
---

# macOS ↔ iOS Cross-Device Handoff

## Objective
Verify the primary cross-device workflow: a session started on macOS can be continued on iPhone (and vice versa) via the commander/mirror protocol. One device is always commander; the other sees a live mirror of the terminal output. Tests cover both directions of handoff, mirror mode enforcement on macOS, and the "Take Command" reclaim flow.

## Risk
- macOS `appWillEnterForeground` equivalent (`didBecomeActiveNotification`) reconnects even in mirror mode → Mac fights iPhone for commander in a loop (same bug as iOS `isInMirrorMode` guard)
- macOS does not show a mirror mode indicator → user types, input silently swallowed
- `onCommanderChanged` callback not wired in macOS view controller → UI doesn't update when commander changes
- If both devices connect at the exact same time, the server may assign commander non-deterministically → test must verify one device ends up in mirror, not both as commanders

## Preconditions
- macOS app and iOS app both logged in to the **same Soyeht server**
- At least one online instance accessible from both devices
- iPhone on same network as Mac (or both on Tailscale)

## How to automate
- **Mac side**: `mcp__XcodeBuildMCP__type_text`, `screenshot`, `snapshot_ui`
- **iOS side**: Appium (`appium_tap`, `appium_type_text`, `appium_screenshot`)
- **Verify output sync**: Screenshot both devices; compare terminal content strings
- **Commander check**: Type a distinguishing string on device A; verify it appears on device B's mirror
- **Mirror mode on Mac**: `snapshot_ui` — look for "mirror" accessibility label or disabled state on input view

## Commander Assignment Rule

**Newest connection = commander. Old connection receives closeCode 4000 and enters mirror mode.**

Confirmed in `QA/domains/websocket-recovery.md` ST-Q-WSRC-007 (passed at 2026-04-12 gate): mobile was connected first (commander). Chrome opened second → mobile received 4000 → mobile entered mirror. Chrome is new commander. The same rule applies to Mac ↔ iPhone.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MXDEV-001 | Open Soyeht instance on **Mac** | Mac WebSocket connects. Mac is commander (input accepted, output visible) | P0 | Yes |
| ST-Q-MXDEV-002 | While Mac is commander (MXDEV-001): open **same instance** on **iPhone** | **Mac** receives closeCode 4000 → Mac enters mirror mode (read-only). **iPhone is new commander**. No crash on either device | P0 | Yes — Appium on iPhone |
| ST-Q-MXDEV-003 | MXDEV-002 state: type `echo phone-to-mac` on **iPhone** (commander) | Output appears on iPhone terminal. **Same output visible on Mac** mirror within 2 seconds | P0 | Yes — compare screenshots |
| ST-Q-MXDEV-004 | Mac is in mirror mode. Mac clicks "Take Command" (reclaim) | Mac reconnects as newest connection → **Mac is commander. iPhone receives closeCode 4000 → iPhone enters mirror**. Mac input works | P1 | Assisted |
| ST-Q-MXDEV-005 | MXDEV-004 state: type `echo mac-to-phone` on **Mac** (commander) | Output appears on Mac terminal. **Same output visible on iPhone** mirror within 2 seconds | P0 | Yes — compare screenshots |
| ST-Q-MXDEV-006 | Mac is in mirror mode (MXDEV-002): switch macOS app to background (Cmd+H) and back | Mac does **NOT** auto-reconnect as commander after `didBecomeActiveNotification` fires — `isInMirrorMode` guard prevents it. iPhone stays commander | P1 | Yes — verify no second WS connection on server |
| ST-Q-MXDEV-007 | iPhone taps "Take Command" while Mac is commander (MXDEV-004/005 state) | iPhone reconnects as newest connection → **iPhone is commander. Mac receives closeCode 4000 → Mac enters mirror** | P1 | Yes — Appium "Take Command" tap |
| ST-Q-MXDEV-008 | **Start on iPhone** (commander). Open same instance on **Mac** | Mac is newest connection → **Mac becomes commander. iPhone receives closeCode 4000 → iPhone enters mirror**. iPhone shows mirror indicator | P1 | Yes |
| ST-Q-MXDEV-009 | Mac is commander, iPhone is mirror: close Mac Soyeht tab (Cmd+W) | WS closes cleanly. iPhone loses mirror feed; iPhone may reconnect as sole commander on next interaction. No crash | P1 | Yes |
| ST-Q-MXDEV-010 | Mac is in mirror mode (iPhone is commander for instance A): open a **second** Soyeht tab on Mac (different instance B) | New Mac tab connects to instance B → Mac is commander for B. Mac mirror tab for A is unchanged. Both tabs independent | P2 | Assisted |

## Notes

**The core cross-device story:** The tmux session on the server is the shared state. Both Mac and iPhone connect to the same PTY/tmux session. The commander sends input; the mirror receives output read-only. Switching commander means the server reassigns which WebSocket is the "writer" for that PTY.

**"Take Command" on macOS:** The exact UI (button, toolbar item, banner with button) is TBD during implementation. Update MXDEV-007 automation once the UI is confirmed.

**Timing sensitivity:** MXDEV-003 and MXDEV-005 allow 2s for output propagation (server → WS → render). If the test environment is slow (Tailscale + high latency), extend to 5s before marking as FAIL.
