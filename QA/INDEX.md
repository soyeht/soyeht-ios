# QA Master Index

Source of truth para QA do Soyeht iOS. Regra: **arquivo com data = execucao; arquivo sem data = plano**.

---

## Release Gate

Para fazer deploy, os seguintes niveis devem estar verdes:

| Nivel | Obrigatorio para | O que roda |
|-------|-------------------|------------|
| `quick` | Qualquer deploy | Unit tests (backend + frontend + iOS + SwiftTerm) + API contract smoke |
| `standard` | Deploy normal | quick + Appium smoke no iPhone (8 steps) |
| `full` | Feature grande | standard + suites automaticas criticas |
| `release` | Release candidate | full + suites assisted/manual + cross-server + relatorio |

---

## Domain Test Plans

| Domain | File | IDs | Profile | Automation | Device |
|--------|------|-----|---------|------------|--------|
| Auth & Session | [auth-session.md](domains/auth-session.md) | ST-Q-AUTH-001..005 | quick | auto | No |
| Instance List & Actions | [instance-list-actions.md](domains/instance-list-actions.md) | ST-Q-INST-001..009 | quick | auto | Yes |
| Terminal & WebSocket | [terminal-websocket.md](domains/terminal-websocket.md) | ST-Q-TERM-001..006 | quick | auto | Yes |
| Workspace Management | [workspace-management.md](domains/workspace-management.md) | ST-Q-WORK-001..005 | standard | auto | Yes |
| Tmux Window & Pane | [tmux-window-pane.md](domains/tmux-window-pane.md) | ST-Q-TMUX-001..009 | standard | auto | Yes |
| Claw Store & Deploy | [claw-store-deploy.md](domains/claw-store-deploy.md) | ST-Q-CLAW-001..012 | standard | auto | Yes |
| Deep Links | [deep-links.md](domains/deep-links.md) | ST-Q-DEEP-001..011 | full | assisted | Yes |
| Multi-Server | [multi-server.md](domains/multi-server.md) | ST-Q-MSRV-001..012 | full | assisted | Yes |
| WebSocket Recovery | [websocket-recovery.md](domains/websocket-recovery.md) | ST-Q-WSRC-001..010 | full | assisted | Yes |
| Attachments & Permissions | [attachments-permissions.md](domains/attachments-permissions.md) | ST-Q-ATCH-001..014 | full | assisted | Yes |
| Settings Live | [settings-live.md](domains/settings-live.md) | ST-Q-SETS-001..007 | full | assisted | Yes |
| Rotation & Resize | [rotation-resize.md](domains/rotation-resize.md) | ST-Q-ROTX-001..007 | release | manual | Yes |
| Empty States | [empty-states.md](domains/empty-states.md) | ST-Q-EMPT-001..007 | standard | auto | Yes |
| Voice Input | [voice-input.md](domains/voice-input.md) | ST-Q-VOIC-001..007 | release | manual | Yes |
| Error Handling | [error-handling.md](domains/error-handling.md) | ST-Q-ERR-001..004 | standard | assisted | Yes |
| Navigation State | [navigation-state.md](domains/navigation-state.md) | ST-Q-NAV-001..002 | standard | auto | Yes |

---

## Severity Guide

| Severity | Description | Example |
|----------|-------------|---------|
| **P0 - Blocker** | App crashes or core flow completely broken | Instance list empty, terminal won't connect, auth fails |
| **P1 - Critical** | Major feature broken but app doesn't crash | Can't create workspaces, can't stop instances, claw store empty |
| **P2 - Major** | Feature partially broken | Wrong instance status, workspace name shows UUID |
| **P3 - Minor** | Cosmetic or edge case | Claw type tag shows wrong label |

---

## Regression Risk Map

Areas most likely to break, ordered by risk:

1. Instance list empty (P0) — `data` key not read from list envelope
2. Terminal won't connect (P0) — workspace `session_id` not decoded (snake_case)
3. Session not persisting (P0) — `session_token` not decoded from auth response
4. WebSocket dead after background (P0) — foreground recovery doesn't reconnect
5. Deep link cold launch fails (P0) — `pendingDeepLink` not consumed
6. Instance actions fail 404 (P1) — old URL path still used
7. Action buttons crash (P1) — 204 empty body parsed as JSON
8. Logout server A kills server B (P1) — keychain dict cleared entirely
9. Commander/mirror loop (P1) — foreground reconnect ignores `isInMirrorMode`
10. Claw store empty (P1) — `data` key not read
11. Tmux tabs missing (P1) — `data` key not read from window/pane list
12. Deploy form broken (P1) — resource options decode failure
13. Invite saves wrong host (P1) — uses deep link host instead of `redeemResponse.server.host`
14. Terminal garbled after rotation (P2) — WebSocket resize message dropped
15. Attachment temp URLs expired (P2) — PHPicker results not copied
16. Wrong display names (P2) — snake_case `display_name` not decoded
17. Settings not applied live (P3) — NotificationCenter observer removed
18. Wrong timestamps (P3) — `created_at` format parsing

---

## Quick Smoke Test (8 steps, ~5 min)

1. **Open app** — instance list loads (not empty)
2. **Tap instance** — terminal connects, prompt visible
3. **Create workspace** — new session appears
4. **Switch window tab** — content changes
5. **Background app 10s, return** — terminal still responsive
6. **Rotate to landscape and back** — terminal re-renders correctly
7. **Open deep link from Safari** (valid pair token) — pairing completes
8. **Go back, pull refresh** — instances reload

---

## QA Runs (most recent first)

| Date | Focus | Pass/Fail | Report |
|------|-------|-----------|--------|
| 2026-04-06 | History View | 26/33 PASS (79%) | [report](runs/2026-04-06-history-view/report.md) |
| 2026-04-06 | Live Activity Deploy | 4/5 PASS | [report](runs/2026-04-06-live-activity-deploy/report.md) |
| 2026-04-05 | Pane/Window/Tab | 44/44 PASS (100%) | [report](runs/2026-04-05-pane-window-tab/report.md) |

---

## Fixtures & Cleanup

- Test instances use prefix `test-qa-` (e.g., `test-qa-deploy-001`)
- NEVER destroy instances without `test-qa-` prefix
- Cleanup after each run; mandatory for `release` level
- Destructive suites: prefer Mac backend. <backend-host> for read-only or `test-qa-*` only.
