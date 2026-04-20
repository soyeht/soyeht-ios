# QA Master Index

Source of truth for Soyeht iOS QA. Rule: **file with a date = execution log; file without a date = plan**.

---

## Current QA Environment

- Web/API base: `https://<host>.<tailnet>.ts.net`
- Terminal access: `ssh devs`
- Override the API target for automation with `QA_BASE_URL` or `SOYEHT_BASE_URL` when needed

---

## Release Gate

To ship a deploy, the following levels must be green:

| Level | Required for | What runs |
|-------|--------------|-----------|
| `quick` | Any deploy | Unit tests (backend + frontend + iOS + SwiftTerm) + API contract smoke |
| `standard` | Normal deploy | quick + Appium smoke on iPhone (8 steps) |
| `full` | Large feature | standard + critical automated suites |
| `release` | Release candidate | full + assisted/manual suites + cross-server + report |

---

## Domain Test Plans

### iOS (existing)

| Domain | File | IDs | Profile | Automation | Device |
|--------|------|-----|---------|------------|--------|
| Auth & Session | [auth-session.md](domains/auth-session.md) | ST-Q-AUTH-001..005 | quick | auto | No |
| Instance List & Actions | [instance-list-actions.md](domains/instance-list-actions.md) | ST-Q-INST-001..009 | quick | auto | Yes |
| Terminal & WebSocket | [terminal-websocket.md](domains/terminal-websocket.md) | ST-Q-TERM-001..006 | quick | auto | Yes |
| Workspace Management | [workspace-management.md](domains/workspace-management.md) | ST-Q-WORK-001..005 | standard | auto | Yes |
| Tmux Window & Pane | [tmux-window-pane.md](domains/tmux-window-pane.md) | ST-Q-TMUX-001..009 | standard | auto | Yes |
| Scrollback Panel | [scrollback-panel.md](domains/scrollback-panel.md) | ST-Q-SCRL-001..007 | standard | assisted | Yes |
| Claw Store & Deploy | [claw-store-deploy.md](domains/claw-store-deploy.md) | ST-Q-CLAW-001..024 | standard | auto | Yes |
| Deep Links | [deep-links.md](domains/deep-links.md) | ST-Q-DEEP-001..011 | full | assisted | Yes |
| Paired Macs Flow (Fase 2) | [paired-macs-flow.md](domains/paired-macs-flow.md) | ST-Q-PM-001..013 | standard | auto | Yes |
| Multi-Server | [multi-server.md](domains/multi-server.md) | ST-Q-MSRV-001..012 | full | assisted | Yes |
| Multi-Server Fan-Out | [multi-server-fanout.md](domains/multi-server-fanout.md) | ST-Q-MFAN-001..012 | standard | auto | Yes |
| WebSocket Recovery | [websocket-recovery.md](domains/websocket-recovery.md) | ST-Q-WSRC-001..010 | full | assisted | Yes |
| Attachments & Permissions | [attachments-permissions.md](domains/attachments-permissions.md) | ST-Q-ATCH-001..014 | full | assisted | Yes |
| File Browser | [file-browser.md](domains/file-browser.md) | ST-Q-BROW-001..025 | full | assisted | Yes |
| Settings Live | [settings-live.md](domains/settings-live.md) | ST-Q-SETS-001..007 | full | assisted | Yes |
| Rotation & Resize | [rotation-resize.md](domains/rotation-resize.md) | ST-Q-ROTX-001..007 | release | manual | Yes |
| Empty States | [empty-states.md](domains/empty-states.md) | ST-Q-EMPT-001..007 | standard | auto | Yes |
| Voice Input | [voice-input.md](domains/voice-input.md) | ST-Q-VOIC-001..007 | release | manual | Yes |
| Error Handling | [error-handling.md](domains/error-handling.md) | ST-Q-ERR-001..004 | standard | assisted | Yes |
| Navigation State | [navigation-state.md](domains/navigation-state.md) | ST-Q-NAV-001..002 | standard | auto | Yes |

### macOS (new — feat/macos-native)

| Domain | File | IDs | Profile | Automation | Device |
|--------|------|-----|---------|------------|--------|
| macOS Auth & Session | [mac-auth.md](domains/mac-auth.md) | ST-Q-MAUTH-001..007 | quick | assisted | No |
| macOS Tab Management | [mac-tab-management.md](domains/mac-tab-management.md) | ST-Q-MTAB-001..010 | quick | assisted | No |
| macOS Workspace + Pane Lifecycle | [workspace-pane-lifecycle.md](domains/workspace-pane-lifecycle.md) | ST-Q-WPL-001..063 | standard | assisted | No |
| macOS Local Shell | [mac-local-shell.md](domains/mac-local-shell.md) | ST-Q-MLSH-001..007 | quick | assisted | No |
| macOS Soyeht Terminal | [mac-soyeht-terminal.md](domains/mac-soyeht-terminal.md) | ST-Q-MWST-001..009 | quick | assisted | No |
| macOS Dev Workflow | [mac-dev-workflow.md](domains/mac-dev-workflow.md) | ST-Q-MDEV-001..011 | standard | assisted | No |
| macOS ↔ iOS Cross-Device | [mac-cross-device.md](domains/mac-cross-device.md) | ST-Q-MXDEV-001..010 | full | assisted | Yes (iPhone) |
| macOS Window Management | [mac-window-management.md](domains/mac-window-management.md) | ST-Q-MWIN-001..007 | standard | assisted | No |

---

## Severity Guide

| Severity | Description | Example |
|----------|-------------|---------|
| **P0 - Blocker** | App crashes or core flow completely broken | Instance list empty, terminal won't connect, auth fails |
| **P1 - Critical** | Major feature broken but app does not crash | Cannot create workspaces, cannot stop instances, claw store empty |
| **P2 - Major** | Feature partially broken | Wrong instance status, workspace name shows UUID |
| **P3 - Minor** | Cosmetic or edge case | Claw type tag shows wrong label |

---

## macOS Regression Risk Map

macOS-specific risks, ordered by probability:

1. Local shell PTY not started (P0) — `LocalShellViewController.viewDidLoad` misses `startProcess`
2. Soyeht tab input not reaching keyboard (P0) — `window?.makeFirstResponder` not called in `connect()`
3. Tabs open as separate windows instead of grouped (P0) — `tabbingIdentifier` missing on one window controller class
4. Auth check bypassed on launch (P0) — NSDocument removal left AppDelegate `applicationDidFinishLaunching` without auth logic
5. Mirror mode reconnect loop on macOS (P1) — `didBecomeActiveNotification` fires without checking `isInMirrorMode`
6. WS resize message not sent after Mac wake (P1) — `sendResize` not called in reconnect path triggered by `didBecomeActiveNotification`
7. Instance picker connects with invalid session (P1) — `buildWebSocketURL` called without prior `createWorkspace` when no workspace exists
8. Duplicate workspace creation (P1) — `createWorkspace` called even when existing workspace found in `listWorkspaces`
9. Clipboard paste target wrong tab (P2) — NSPasteboard write in one tab fires event that switches first responder
10. Terminal title escape not updating tab title (P2) — `setTerminalTitle` delegate method not wired to `window?.title`

---

## iOS Regression Risk Map

Areas most likely to break, ordered by risk:

1. Instance list empty (P0) - `data` key not read from list envelope
2. Terminal will not connect (P0) - workspace `session_id` not decoded (snake_case)
3. Session not persisted (P0) - `session_token` not decoded from auth response
4. WebSocket dead after background (P0) - foreground recovery does not reconnect
5. Deep link cold launch fails (P0) - `pendingDeepLink` not consumed
6. Instance actions fail 404 (P1) - old URL path still used
7. Action buttons crash (P1) - 204 empty body parsed as JSON
8. Logout on server A kills server B (P1) - keychain dictionary cleared entirely
9. Commander/mirror loop (P1) - foreground reconnect ignores `isInMirrorMode`
10. Claw store empty (P1) - `data` key not read
11. Tmux tabs missing (P1) - `data` key not read from window/pane list
12. Deploy form broken (P1) - `resource-options` decode failure
13. Deploy fallback lies about limits (P1) - client reuses stale local max values instead of server-driven ranges
14. macOS deploy rejected (P1) - fallback or live flow sends `disk_gb` when disk should be server-managed
15. Invite saves wrong host (P1) - uses deep link host instead of `redeemResponse.server.host`
16. Terminal garbled after rotation (P2) - WebSocket resize message dropped
17. Attachment temp URLs expired (P2) - PHPicker results not copied
18. Wrong display names (P2) - snake_case `display_name` not decoded
19. Settings not applied live (P3) - NotificationCenter observer removed
20. Wrong timestamps (P3) - `created_at` format parsing

---

## Quick Smoke Test (8 steps, ~5 min)

1. **Open app** - instance list loads (not empty)
2. **Tap instance** - terminal connects, prompt visible
3. **Create workspace** - new session appears
4. **Switch window tab** - content changes
5. **Background app for 10s, return** - terminal still responsive
6. **Rotate to landscape and back** - terminal re-renders correctly
7. **Open deep link from Safari** (valid pair token) - pairing completes
8. **Go back, pull to refresh** - instances reload

---

## QA Runs (most recent first)

| Date | Focus | Pass/Fail | Report |
|------|-------|-----------|--------|
| 2026-04-20 | **WPL mouse drag fix** (WPL-056..058 — root cause: titlebar drag intercept) | 3/3 PASS via native-devtools (window.isMovable=false + leftMouseDragged monitor) | [report](runs/2026-04-20-wpl-mouse-drag/report.md) |
| 2026-04-20 | **WPL auto** (WPL-001..024 unit tests, 162 total) | 19 PASS / 0 FAIL / 4 SKIP | [report](runs/2026-04-20-wpl-automated/report.md) |
| 2026-04-16 | **Full Gate** (File Browser, Settings, WS Recovery, Deep Links) | 335 PASS / 0 FAIL / ~13 SKIP | [report](runs/2026-04-16-gate-full/gate-report.md) |
| 2026-04-12 | **Full Gate** (17 domains) | 928/931 PASS (99.7%) | [report](runs/2026-04-12/gate-report.md) |
| 2026-04-08 | Full Gate | 878/888 PASS (98.9%) BLOCKED | [report](runs/2026-04-08/gate-report.md) |
| 2026-04-06 | History View | 26/33 PASS (79%) | [report](runs/2026-04-06-history-view/report.md) |
| 2026-04-06 | Live Activity Deploy | 4/5 PASS | [report](runs/2026-04-06-live-activity-deploy/report.md) |
| 2026-04-05 | Pane/Window/Tab | 44/44 PASS (100%) | [report](runs/2026-04-05-pane-window-tab/report.md) |

---

## Fixtures & Cleanup

- Test instances use prefix `test-qa-` (for example, `test-qa-deploy-001`)
- NEVER destroy instances without the `test-qa-` prefix
- Clean up after each run; mandatory for `release` level
- For destructive suites, prefer the Mac backend. Use <backend-host> for read-only checks or `test-qa-*` only.
