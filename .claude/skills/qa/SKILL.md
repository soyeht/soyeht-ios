---
name: qa
description: Soyeht QA — run tests, check status, validate before deploy. Single entry point for all QA operations.
user_invocable: true
---

# /qa

Single command for all QA operations on Soyeht iOS + theyos backend.

## Usage

```
/qa                     → show status (recent runs, coverage gaps)
/qa smoke               → quick 8-step smoke test on iPhone (~5 min)
/qa gate                → full pre-deploy gate (unit tests + contract + UI smoke)
/qa gate quick          → unit tests + contract smoke only (no device needed)
/qa run <suite>         → run a specific test suite
/qa contract            → run API contract smoke tests (no device needed)
```

### Available suites for `/qa run <suite>`

| Suite | What it tests |
|-------|---------------|
| `api` | Auth, instance list, workspace, claw store API |
| `terminal` | Terminal connection, WebSocket, recovery, resize |
| `deeplinks` | Deep link cold/warm/invalid/invite flows |
| `multiserver` | Multi-server isolation and state separation |
| `attachments` | All 5 attachment types + permissions |
| `settings` | Live settings updates in open terminal |
| `voice` | Voice input (mostly manual) |
| `claws` | Claw store browse + deploy flow |

---

## IMPORTANT RULES

- **Always confirm with the user before running tests.** QA has side effects. The user speaks Portuguese — "sim" means "yes", NOT "simulator".
- **UI tests (phases 4-5) MUST run on the physical iPhone "Caio Salgado" via Appium MCP (UDID: <ios-udid>, bundleId: com.soyeht.app).** Do NOT use the iOS Simulator for UI smoke or domain suites. The simulator is ONLY used for unit tests (phase 2).
- **Never destroy instances without `test-qa-` prefix.**
- This skill is a **thin wrapper**. Test plans live in `QA/domains/`. Read them for steps.
- Save evidence to `QA/runs/YYYY-MM-DD/screenshots/`.
- Never stop on a single failure — record and continue.

## ENVIRONMENT

- **Device under test**: iPhone <qa-device> (UDID: <ios-udid>, iOS 18.5)
- **Mac backend**: http://localhost:8892
- **Linux backend (<backend-host>)**: ssh <user>@<host-ip>, Tailscale network
- **Generate pair token**: Run `cd ~/Documents/theyos && soyeht pair` on the Mac to get a deep link (`theyos://pair?token=X&host=Y&name=Z`)
- **Contract smoke script**: `./QA/contract-smoke.sh` (pass TOKEN=xxx for authenticated tests)
- **Appium session**: Use `mcp__appium-mcp__create_session` with platformName: iOS, udid: <ios-udid>, bundleId: com.soyeht.app, automationName: XCUITest

---

## Mode: `/qa` (status — default, no args)

Show QA status. Read-only, no tests executed.

1. Read `QA/INDEX.md` for the master domain list
2. List all directories in `QA/runs/` sorted by date
3. For each run, read `report.md` and extract pass/fail/skip counts and bugs
4. Display summary:

```
QA Status
═════════
Runs (last 30 days): N
Total: X pass, Y fail, Z skip (N% pass rate)

Recent:
  YYYY-MM-DD  Suite Name    X/Y PASS  N bugs
  ...

Coverage Gaps:
  ⚠ domain-name — never tested / stale (last: YYYY-MM-DD)
```

If gaps exist, suggest: `Run /qa smoke for a quick check.`

---

## Mode: `/qa smoke`

Quick 8-step critical path check on the iPhone. Read the Quick Smoke Test from `QA/INDEX.md`.

### Preflight
1. Check backend: `curl -s -o /dev/null -w "%{http_code}" http://localhost:8892/healthz`
2. Check iPhone: `xcrun xctrace list devices 2>&1 | grep "<ios-udid>"`
3. Check Appium: `mcp__appium-mcp__list_sessions`
4. Create run dir: `mkdir -p QA/runs/$(date +%Y-%m-%d)/screenshots`
5. **(full level only)** Generate expired-token seeds NOW — they'll expire by Phase 5:
   - `cd ~/Documents/theyos && soyeht pair` → save deep link for ST-Q-DEEP-003 (expires in 15min)
   - `cd ~/Documents/theyos && soyeht pair -d 1m` → save deep link for ST-Q-MSRV-007/008 (expires in 1min, for cross-server token isolation test)

### Execute
Create Appium session (bundleId: com.soyeht.app, udid: <ios-udid>), then:

1. App opens → instance list loads (not empty)
2. Tap instance → terminal connects, prompt visible
3. Create workspace → new session appears
4. Switch window tab → content changes
5. Background app 10s, return → terminal responsive
6. Rotate to landscape and back → re-renders
7. Open deep link from Safari → pairing completes
8. Go back, pull refresh → instances reload

Screenshot after each step. Delete Appium session.

### Report
Write `QA/runs/YYYY-MM-DD/smoke-report.md`. Print verdict: PASS / BLOCKED.

---

## Mode: `/qa gate [quick|standard|full]`

Pre-deploy validation gate. Default level: `standard`.

| Level | What runs | Time |
|-------|-----------|------|
| `quick` | Unit tests + contract smoke (no device) | ~5m |
| `standard` | quick + UI smoke on iPhone (8 steps) | ~10m |
| `full` | standard + critical domain suites (deep links, multi-server, WS recovery) | ~25m |

### Phase 1: Preflight
Same as smoke preflight + record git commit SHAs from both repos.

### Phase 2: Unit Tests (all levels)
Run in parallel where possible:
1. `xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
2. `swift test` (SwiftTerm)
3. `cd ~/Documents/theyos/admin/rust && cargo test --workspace -- --test-threads=1` (Cargo workspace is in admin/rust/, NOT the repo root)
4. `cd ~/Documents/theyos/admin/frontend && npm run test` (if exists)

### Phase 3: Contract Smoke (all levels)
Run `./QA/contract-smoke.sh` or execute equivalent curl checks inline.

### Phase 4: UI Smoke (standard+)
Same as `/qa smoke` mode.

### Phase 5: Domain Suites (full only)
Read ALL domain files from `QA/domains/` where `profile` is `full` or lower. **Run EVERY test, not just the easy ones:**
- Each domain file has a "How to automate" section — follow it
- Generate pair tokens with `cd ~/Documents/theyos && soyeht pair` (Mac) or `ssh <user>@<host-ip> 'cd ~/theyos && soyeht pair'` (<backend-host>)
- Use Chrome DevTools MCP to open web terminal for mirror/commander tests (WSRC-007)
- Use `appium_terminate_app` + `appium_deep_link` for cold launch tests (DEEP-001)
- Use `appium_mobile_background_app(seconds: N)` for background tests
- For WiFi toggle tests: print "Toggle WiFi OFF/ON now" and WAIT for user confirmation
- Only SKIP tests that require waiting 16+ minutes (token expiry) or physical hardware (camera, microphone)
- Use BOTH servers: Mac (localhost:8892) and <backend-host> (ssh <user>@<host-ip>) for multi-server isolation tests

### Report & Verdict
Write `QA/runs/YYYY-MM-DD/gate-report.md`.
- **BLOCKED**: Any P0/P1 failed → list failures
- **PASS WITH WARNINGS**: Only P2/P3 → list warnings
- **PASS**: All green → print `sudo soyeht deploy`

---

## Mode: `/qa run <suite>`

Run a specific domain test suite on the iPhone.

1. Map suite to domain file(s) in `QA/domains/`
2. Read the domain file — it has all test cases
3. Preflight (backend health, iPhone connected if needed)
4. For each test case:
   - **auto**: Execute via Appium MCP, screenshot, record PASS/FAIL
   - **assisted**: Execute automatable part, then print manual step, wait for user
   - **manual**: Print instructions, wait for user input
5. Cleanup: list `test-qa-*` instances, offer to delete
6. Write `QA/runs/YYYY-MM-DD/<suite>-report.md`

---

## Mode: `/qa contract`

Run API contract smoke tests (no device needed, just backend).

Execute `./QA/contract-smoke.sh` or, if TOKEN is needed, prompt user for it first.

Validates: health endpoint, auth rejection, instance list envelope, instance fields, workspace list + session_id, tmux windows/panes envelopes, WebSocket PTY endpoint.

---

## macOS Desktop Automation (native-devtools MCP)

For macOS WPL / workspace-tab tests that require mouse interaction:

### Tab drag reorder
**ALWAYS use `move_mouse` before `drag`** — native-devtools `drag` teleports the cursor
without generating `.mouseMoved` events. The Soyeht window uses `.mouseMoved` to set
`window.isMovable = false` when the cursor is over a tab; without that event, AppKit's
titlebar drag intercepts the gesture and moves the window instead of the tab.

```
# CORRECT — hover first to prime isMovable, then drag
move_mouse(x=<tab_x>, y=<tab_y>)
drag(start_x=<tab_x>, start_y=<tab_y>, end_x=<target_x>, end_y=<tab_y>)

# WRONG — teleports; moves the window instead of the tab
drag(start_x=<tab_x>, start_y=<tab_y>, end_x=<target_x>, end_y=<tab_y>)
```

### Window drag (empty titlebar area)
Same technique — `move_mouse` to the empty titlebar area (right of the last tab),
then `drag`. Verify via `screenshot_origin_x` delta in the screenshot metadata.

### Keyboard shortcuts (macOS WPL)
| Action | Shortcut |
|--------|----------|
| Activate workspace N | `⌘N` (1–9) |
| Move active workspace left | `⌃⌘[` |
| Move active workspace right | `⌃⌘]` |
| Toggle workspace selection | `⌘⌥N` |
| Close active workspace | `⌘⇧W` |
| New conversation | `⌘T` |

### Coordinate reference
Tab bar lives at approximately `y = window_origin_y + 20` in screen coords.
After each drag, check `screenshot_origin_x/y` in the metadata to confirm the
window did NOT move (tab drag) or DID move (window drag).

---

## Error Handling

- Never stop on a single test failure — record and continue
- Appium session loss: reconnect once, then SKIP remaining UI tests
- App crash: screenshot, record P0, relaunch via `appium_activate_app`, continue
- Backend down mid-run: SKIP backend-dependent tests, continue UI-only
- Timeout: 30s per individual test step
