# QA Master Regression — Soyeht iOS

> **Full QA index**: [QA/INDEX.md](QA/INDEX.md)
> **Domain plans**: [QA/domains/](QA/domains/)
> **Run reports**: [QA/runs/](QA/runs/)

---

## Context

The theyOS backend API went through 4 phases of standardization. The iOS app (Soyeht) was updated to match. This document serves as the top-level entry point for QA — it defines the smoke test and links to detailed plans.

### What Changed

| Phase | Change | Impact on iOS |
|-------|--------|---------------|
| 1 - List Envelope | `{"data": [...], "has_more": false}` | Every list screen |
| 2 - snake_case | All JSON fields now snake_case | Every Codable model |
| 3 - 204 No Content | Void actions return empty body | Every action button |
| 4 - Dedicated Endpoints | `POST /instances/{id}/stop` instead of `/actions/stop` | Instance actions |

---

## Pre-Test Checklist

- [ ] Backend running latest code
- [ ] iOS app built from latest commit on `main`
- [ ] At least 1 claw instance running and accessible
- [ ] Admin credentials available (QR code or existing pairing)

---

## Quick Smoke Test (5 minutes)

If you only have time for a quick check, do these 8 steps:

1. **Open app** — instance list loads (not empty) → Phase 1 envelope works
2. **Tap instance** — terminal connects, prompt visible → Phase 2 snake_case works
3. **Create workspace** — new session appears → Phase 3 (204 on void) works
4. **Switch window tab** — content changes → Phase 1 window list + Phase 3 select 204
5. **Background app 10s, return** — terminal still responsive → WebSocket recovery
6. **Rotate to landscape and back** — terminal re-renders → resize message works
7. **Open deep link from Safari** (valid pair token) — pairing completes → deep link warm launch
8. **Go back, pull refresh** — instances reload → full round-trip works

If all 8 pass, the critical paths are working.

---

## Domain Plans

All detailed test cases with stable IDs live in [QA/domains/](QA/domains/):

| Domain | Tests | Profile | Link |
|--------|-------|---------|------|
| Auth & Session | ST-Q-AUTH-001..005 | quick | [auth-session.md](QA/domains/auth-session.md) |
| Instance List & Actions | ST-Q-INST-001..009 | quick | [instance-list-actions.md](QA/domains/instance-list-actions.md) |
| Terminal & WebSocket | ST-Q-TERM-001..006 | quick | [terminal-websocket.md](QA/domains/terminal-websocket.md) |
| Workspace Management | ST-Q-WORK-001..005 | standard | [workspace-management.md](QA/domains/workspace-management.md) |
| Tmux Window & Pane | ST-Q-TMUX-001..009 | standard | [tmux-window-pane.md](QA/domains/tmux-window-pane.md) |
| Claw Store & Deploy | ST-Q-CLAW-001..012 | standard | [claw-store-deploy.md](QA/domains/claw-store-deploy.md) |
| Deep Links | ST-Q-DEEP-001..011 | full | [deep-links.md](QA/domains/deep-links.md) |
| Multi-Server | ST-Q-MSRV-001..012 | full | [multi-server.md](QA/domains/multi-server.md) |
| WebSocket Recovery | ST-Q-WSRC-001..010 | full | [websocket-recovery.md](QA/domains/websocket-recovery.md) |
| Attachments & Permissions | ST-Q-ATCH-001..014 | full | [attachments-permissions.md](QA/domains/attachments-permissions.md) |
| Settings Live | ST-Q-SETS-001..007 | full | [settings-live.md](QA/domains/settings-live.md) |
| Rotation & Resize | ST-Q-ROTX-001..007 | release | [rotation-resize.md](QA/domains/rotation-resize.md) |
| Empty States | ST-Q-EMPT-001..007 | standard | [empty-states.md](QA/domains/empty-states.md) |
| Voice Input | ST-Q-VOIC-001..007 | release | [voice-input.md](QA/domains/voice-input.md) |
| Error Handling | ST-Q-ERR-001..004 | standard | [error-handling.md](QA/domains/error-handling.md) |
| Navigation State | ST-Q-NAV-001..002 | standard | [navigation-state.md](QA/domains/navigation-state.md) |

**Total: 126 test cases across 16 domains.**

---

## Severity Guide

| Severity | Description |
|----------|-------------|
| **P0** | App crashes or core flow completely broken |
| **P1** | Major feature broken but no crash |
| **P2** | Feature partially broken |
| **P3** | Cosmetic or edge case |

---

## Regression Risk Map

See [QA/INDEX.md](QA/INDEX.md#regression-risk-map) for the full ordered list.
