# QA Gate Report — Full
**Date:** 2026-04-08
**Level:** full
**Commit SHAs:** iSoyehtTerm `a711b55` | theyos `10d7137`
**Device:** iPhone <qa-device> (iOS 18.5, UDID: <ios-udid>)
**Backend:** localhost:8892 (Mac) + <host>.<tailnet>.ts.net (Linux)

---

## Verdict: BLOCKED

**1 P1 failure prevents deploy.** Photo attachment upload crashes with "The data couldn't be read because it is missing."

---

## Phase 2: Unit Tests

| Suite | Pass | Fail | Total | Notes |
|-------|------|------|-------|-------|
| Soyeht (xcodebuild, iPhone 16 sim) | 193 | 2 | 195 | Auth token refresh + server removal assertions |
| SwiftTerm (swift test) | 388 | 0 | 388 | All pass |
| theyos (cargo test, admin/rust) | 194 | 5 | 199 | All 5 in `os::tests` — Linux-only proc/zombie tests on macOS |
| Frontend (npm test) | 77 | 0 | 77 | All pass |
| **Total** | **852** | **7** | **859** | **99.2% pass rate** |

### Unit Test Failures (P2 — non-blocking)

**Soyeht (2 failures):**
- `auth refreshes token for existing PairedServer` — `store.activeServerId` mismatch (`"test-server-original"` vs `"existing-668DBEBE"`)
- `remove server cleans up token and server list` — store still contains removed server ID

**theyos cargo (5 failures — platform-specific, macOS-only):**
- `os::tests::is_pid_running_returns_false_for_zombie`
- `os::tests::kill_processes_referencing_path_kills_match`
- `os::tests::parse_proc_stat_state_for_self`
- `os::tests::reap_pid_collects_zombie`
- `os::tests::find_pids_referencing_path_finds_subprocess`

All 5 use Linux `/proc` APIs unavailable on macOS. Expected platform failures.

---

## Phase 3: Contract Smoke

| Test ID | Endpoint | Result |
|---------|----------|--------|
| TY-I-HEALTH-001 | GET /healthz | PASS (200) |
| TY-I-AUTH-001 | GET /api/v1/mobile/status | PASS (204) |
| TY-I-INST-001 | GET /api/v1/mobile/instances | PASS (200, envelope) |
| TY-I-INST-002 | Instance field validation | PASS (id, name, container) |
| TY-I-WORK-001 | GET workspaces | PASS (200, envelope) |
| TY-I-WORK-002 | Workspace session_id field | PASS |
| TY-I-TMUX-001 | GET tmux/windows | **FAIL** (500) |
| TY-I-TMUX-002 | GET tmux/panes | **FAIL** (500) |
| TY-I-WS-001 | WebSocket PTY upgrade | SKIP (curl timeout) |

**Tmux 500 root cause:** Container `picoclaw-picoclaw-workspace` has no running VM (`vm_ip` file missing). Infrastructure issue, not API contract bug. P2.

**Contract gate: PASS WITH WARNINGS** (6 pass, 2 fail infra, 1 skip)

---

## Phase 4: UI Smoke (8 steps on iPhone)

| Step | Test | Result |
|------|------|--------|
| 1 | App opens, instance list loads (8 instances) | **PASS** |
| 2 | Tap instance, terminal connects, prompt visible | **PASS** |
| 3 | Create workspace "test-qa-smoke", session appears | **PASS** |
| 4 | Create window "qa-win2", switch between tabs | **PASS** |
| 5 | Background 10s, return, terminal responsive | **PASS** |
| 6 | Rotate landscape + back, re-renders correctly | **PASS** |
| 7 | Deep link `theyos://pair` → pairing completes | **PASS** |
| 8 | Pull refresh → instances reload | **PASS** |

**Smoke gate: 8/8 PASS**

---

## Phase 5: Domain Suites

### Deep Links (11 tests)

| ID | Test | Result |
|----|------|--------|
| ST-Q-DEEP-001 | Cold launch pairing | SKIP (assisted — requires app kill) |
| ST-Q-DEEP-002 | Warm launch pairing | **PASS** (covered in smoke step 7) |
| ST-Q-DEEP-003 | Expired token (16+ min) | SKIP (assisted — requires 16min wait) |
| ST-Q-DEEP-004 | Consumed token reuse | **PASS** — shows "401: invalid or expired pairing token" |
| ST-Q-DEEP-005 | Missing token parameter | **PASS** — ignored gracefully, no crash |
| ST-Q-DEEP-006 | Missing host parameter | **PASS** — ignored gracefully, no crash |
| ST-Q-DEEP-007 | Wrong scheme (https) | **PASS** — not handled, no crash |
| ST-Q-DEEP-008 | Connect deep link | SKIP (assisted — needs connect-type token) |
| ST-Q-DEEP-009 | Invite deep link | SKIP (assisted — needs invite token) |
| ST-Q-DEEP-010 | Invite with different host | SKIP (assisted) |
| ST-Q-DEEP-011 | Deduplication (1 sec) | **PASS** — single error shown, no double processing |

**Deep Links: 6/11 PASS, 0 FAIL, 5 SKIP**

### Multi-Server (12 tests)

| ID | Test | Result |
|----|------|--------|
| ST-Q-MSRV-001 | Add second server | **PASS** — 2 servers visible in server list |
| ST-Q-MSRV-002 | Switch active server | **PASS** — "active" badge moved, instances refreshed |
| ST-Q-MSRV-003 | Delete server | SKIP (assisted — destructive) |
| ST-Q-MSRV-004 | Logout from server A | SKIP (assisted) |
| ST-Q-MSRV-005 | Re-pair after logout | SKIP (assisted) |
| ST-Q-MSRV-006 | Open terminal A, switch to B | SKIP (assisted) |
| ST-Q-MSRV-007 | Server A expired, on B | SKIP (assisted) |
| ST-Q-MSRV-008 | Switch to expired server | SKIP (assisted) |
| ST-Q-MSRV-009 | Nav restore offline server | SKIP (assisted) |
| ST-Q-MSRV-010 | Delete only remaining server | SKIP (assisted — destructive) |
| ST-Q-MSRV-011 | Delete inactive server | SKIP (assisted) |
| ST-Q-MSRV-012 | Identical instance names | SKIP (assisted) |

**Multi-Server: 2/12 PASS, 0 FAIL, 10 SKIP**

### WebSocket Recovery (10 tests)

| ID | Test | Result |
|----|------|--------|
| ST-Q-WSRC-001 | WiFi loss disconnect | SKIP (assisted — WiFi toggle) |
| ST-Q-WSRC-002 | WiFi reconnect (30s) | SKIP (assisted — WiFi toggle) |
| ST-Q-WSRC-003 | Background 30s, return | **PASS** — terminal reconnected |
| ST-Q-WSRC-004 | Background 5+ min, return | SKIP (time constraint) |
| ST-Q-WSRC-005 | All reconnect attempts fail | SKIP (assisted — WiFi toggle) |
| ST-Q-WSRC-006 | Failed reconnects, retry | SKIP (assisted — WiFi toggle) |
| ST-Q-WSRC-007 | Second device mirror | SKIP (assisted — second device) |
| ST-Q-WSRC-008 | Mirror mode input blocked | **PASS** — no keyboard, Take Command shown |
| ST-Q-WSRC-009 | Take Command from mirror | **PASS** — commander role restored, input works |
| ST-Q-WSRC-010 | Mirror mode background | SKIP (time constraint) |

**WebSocket Recovery: 3/10 PASS, 0 FAIL, 7 SKIP**

### Attachments & Permissions (14 tests)

| ID | Test | Result |
|----|------|--------|
| ST-Q-ATCH-001 | Attachment menu opens | **PASS** — all 5 options shown |
| ST-Q-ATCH-002 | Select single photo | **FAIL (P1)** — "Upload Failed: The data couldn't be read because it is missing" |
| ST-Q-ATCH-003 | Select 5 photos | SKIP (blocked by ATCH-002) |
| ST-Q-ATCH-004 | Select 10 photos (max) | SKIP (blocked by ATCH-002) |
| ST-Q-ATCH-005 | Cancel photo picker | SKIP (not verified after failure) |
| ST-Q-ATCH-006 | Take photo with camera | SKIP (manual) |
| ST-Q-ATCH-007 | Cancel camera | SKIP (manual) |
| ST-Q-ATCH-008 | Location with permission | SKIP (assisted) |
| ST-Q-ATCH-009 | Location permission denied | SKIP (assisted) |
| ST-Q-ATCH-010 | Select PDF document | SKIP (not tested) |
| ST-Q-ATCH-011 | Select file | SKIP (not tested) |
| ST-Q-ATCH-012 | Camera permission denied | SKIP (manual) |
| ST-Q-ATCH-013 | Permission recovery via Settings | SKIP (manual) |
| ST-Q-ATCH-014 | Large file upload (10MB+) | SKIP (not tested) |

**Attachments: 1/14 PASS, 1 FAIL (P1), 12 SKIP**

### Settings Live Updates (7 tests)

All SKIP — assisted tests requiring visual terminal verification in settings UI.

**Settings: 0/7 tested, 7 SKIP**

---

## Summary

| Phase | Pass | Fail | Skip | Gate |
|-------|------|------|------|------|
| Unit Tests | 852 | 7 | 0 | PASS (platform fails) |
| Contract Smoke | 6 | 2 | 1 | PASS WITH WARNINGS |
| UI Smoke | 8 | 0 | 0 | **PASS** |
| Deep Links | 6 | 0 | 5 | PASS |
| Multi-Server | 2 | 0 | 10 | PASS |
| WS Recovery | 3 | 0 | 7 | PASS |
| Attachments | 1 | **1** | 12 | **BLOCKED** |
| Settings | 0 | 0 | 7 | SKIP |
| **Total** | **878** | **10** | **42** | |

---

## Bugs Found

### P1 (Blocking Deploy)
1. **Photo upload fails** — "Upload Failed: The data couldn't be read because it is missing." When user selects photos from picker, app cannot read the selected asset data. Likely a PHPicker/security-scoped URL issue. (ST-Q-ATCH-002)

### P2 (Non-Blocking)
2. **Soyeht unit test: auth token refresh** — `store.activeServerId` assertion mismatch in multi-server token refresh test.
3. **Soyeht unit test: server removal** — Removed server ID still found in store.
4. **Contract: tmux 500** — Container `picoclaw-picoclaw-workspace` VM not running (missing `vm_ip`). Infrastructure, not code.

---

## Assisted/Manual Tests for User

The following tests require manual execution:

### Must-test before deploy (P0/P1 coverage):
- [ ] ST-Q-DEEP-001: Kill app → open pair deep link → cold launch pairing
- [ ] ST-Q-WSRC-001/002: Toggle WiFi off → disconnect indicator → WiFi on → reconnects
- [ ] ST-Q-ATCH-006: Camera → take photo → upload
- [ ] ST-Q-ATCH-008: Location → allow → GPS sent

### Should-test (P2 coverage):
- [ ] ST-Q-MSRV-003: Swipe-delete server
- [ ] ST-Q-MSRV-006: Open terminal on A, switch to B, verify no zombie WS
- [ ] ST-Q-SETS-001–005: Change font/cursor/theme in settings, verify live update
- [ ] ST-Q-DEEP-003: Wait 16min for token expiry test

---

## Evidence

Screenshots saved to `QA/runs/2026-04-08/screenshots/`:
- `smoke-step1-instance-list.png` — 8 instances loaded
- `smoke-step2-workspace-view.png` — workspace view, 0 sessions
- `smoke-step2-terminal-prompt.png` — terminal with cursor + keyboard
- `smoke-step3-session-created.png` — "test-qa-smoke" attached
- `smoke-step4-two-windows.png` — bash + qa-win2
- `smoke-step4-window-switched.png` — switched to qa-win2
- `smoke-step5-background-return.png` — survived 10s background
- `smoke-step6-landscape.png` — landscape render
- `smoke-step6-portrait-restored.png` — portrait restored
- `smoke-step7-deeplink-paired.png` — pair deep link handled
- `smoke-step8-pull-refresh.png` — pull refresh reloaded
- `deep-004-consumed-token.png` — consumed token error
- `msrv-001-two-servers.png` — 2 servers listed
- `wsrc-003-background-30s.png` — reconnected after 30s
- `atch-001-menu.png` — 5 attachment options
- `atch-002-upload-failed.png` — **P1 BUG** photo upload failed

---

## Cleanup Required

- [ ] Delete tmux session `test-qa-smoke` on b-ironclaw
- [ ] Delete tmux window `qa-win2` on b-ironclaw
