# QA Master Index

Source of truth for Soyeht iOS QA. Rule: **file with a date = execution log; file without a date = plan**.

---

## Current QA Environment

- Keep machine-specific QA config in a local `.env.local` copied from `.env.example`
- Set `SOYEHT_BASE_URL` / `QA_BASE_URL` there for the target backend
- Set `SOYEHT_SSH_HOST`, `SOYEHT_IOS_UDID`, and `SOYEHT_WDA_TEAM_ID` there for remote/Appium flows

### Local signing

The `.xcodeproj/project.pbxproj` files ship with literal placeholders `"<IOS_TEAM_ID>"` / `"<MAC_TEAM_ID>"` for the Apple Developer Team. Physical-device builds require replacing them locally — open Signing & Capabilities in Xcode and pick your team (Xcode writes a per-user override outside of git), or export `SOYEHT_WDA_TEAM_ID` in `.env.local` for the QA Appium path. Simulator builds work as-is.

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
| macOS Workspace + Pane Lifecycle | [workspace-pane-lifecycle.md](domains/workspace-pane-lifecycle.md) | ST-Q-WPL-001..066 | standard | assisted | No |
| macOS Local Shell | [mac-local-shell.md](domains/mac-local-shell.md) | ST-Q-MLSH-001..007 | quick | assisted | No |
| macOS Soyeht Terminal | [mac-soyeht-terminal.md](domains/mac-soyeht-terminal.md) | ST-Q-MWST-001..009 | quick | assisted | No |
| macOS Dev Workflow | [mac-dev-workflow.md](domains/mac-dev-workflow.md) | ST-Q-MDEV-001..011 | standard | assisted | No |
| macOS ↔ iOS Cross-Device | [mac-cross-device.md](domains/mac-cross-device.md) | ST-Q-MXDEV-001..010 | full | assisted | Yes (iPhone) |
| macOS Window Management | [mac-window-management.md](domains/mac-window-management.md) | ST-Q-MWIN-001..007 | standard | assisted | No |
| Soyeht MCP Automation | [soyeht-mcp-automation.md](domains/soyeht-mcp-automation.md) | ST-Q-MCPA-001..120 | full | auto + assisted | No |

### macOS (new — feat/claw-store-macos)

| Domain | File | IDs | Profile | Automation | Device |
|--------|------|-----|---------|------------|--------|
| macOS Welcome + theyOS Auto-Install | [mac-welcome-onboarding.md](domains/mac-welcome-onboarding.md) | ST-Q-MWEL-001..021 | standard | assisted | No |
| macOS theyOS Installer Contract | [mac-theyos-installer-contract.md](domains/mac-theyos-installer-contract.md) | ST-Q-TINS-001..028 | full | assisted | No |
| macOS Claw Store Window | [mac-claw-store-window.md](domains/mac-claw-store-window.md) | ST-Q-MCSW-001..016 | standard | assisted | No |
| macOS Claw Drawer (sidebar) | [mac-claw-drawer.md](domains/mac-claw-drawer.md) | ST-Q-MCDR-001..018 | standard | assisted | No |
| macOS Pane ↔ Installed Claws | [mac-pane-claws-integration.md](domains/mac-pane-claws-integration.md) | ST-Q-MPCI-001..018 | standard | assisted | No |
| macOS AgentType Reshape + Snapshot Migration | [mac-agent-type-migration.md](domains/mac-agent-type-migration.md) | ST-Q-MATM-001..014 | quick | auto | No |
| SoyehtCore Session Layer Parity (Fase 0) | [soyeht-core-session-parity.md](domains/soyeht-core-session-parity.md) | ST-Q-SCSP-001..014 | quick | auto | No |
| SoyehtCore Shared Claw Types (Fase 1) | [soyeht-core-claw-shared.md](domains/soyeht-core-claw-shared.md) | ST-Q-SCCS-001..016 | standard | auto | No |

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
11. Tab drag moves the window instead of reordering (P1) — `.titled + .fullSizeContentView` hands the titlebar strip to AppKit's native drag loop; only honored `mouseDownCanMoveWindow=false` when hit view is opaque. Fixed via `surfaceBase` bg on WorkspaceTabsView + inactive WorkspaceTabView (was `.clear`)
12. Empty titlebar no longer drags window (P1) — inverse of #11; setting `mouseDownCanMoveWindow=false` on WindowTopBarView to fix #11 regressed window-drag. Fix keeps WindowTopBarView drag-capable and relies on child view opacity for the tab short-circuit
13. Welcome window hidden by main window on first launch (P0) — `AppDelegate.applicationDidFinishLaunching` calls `openNewMainWindow()` before checking `SessionStore.pairedServers.isEmpty`. Branching must happen before main window creation
14. theyOS installer uses shell-resolved `brew` (P0) — `TheyOSInstaller` must use an absolute path (`/opt/homebrew/bin/brew` on Apple Silicon, `/usr/local/bin/brew` on Intel) since Process doesn't inherit a login shell's PATH
15. `soyeht start` hangs without non-interactive flag (P0) — **MITIGATED (2026-04-21, PR #9 fix)**: CLI already daemonizes via `Command::spawn` and `--yes` covers the single confirmation prompt (no EULA exists). As a safety net, `TheyOSInstaller.runProcess` now wraps every spawn with a 180s defensive timeout (`defaultProcessTimeout`) that SIGTERMs the child and throws `subprocessTimedOut` if the CLI ever regresses. Covered by `TheyOSInstallerTests.test_timeout_sendsSIGTERMAndThrowsSubprocessTimedOut`
16. Health probe timeout too tight (P1) — first cold boot of theyOS can take 10s+; probe must tolerate ≥20s before giving up
17. Bootstrap token trailing newline breaks Bearer header (P1) — `TheyOSAutoPairService` must strip whitespace when reading `~/.theyos/bootstrap-token`, else backend returns 401
18. `InstalledClawsProvider` not reset on server switch (P1) — multi-server: switching active server must refresh the cache, else pane picker shows claws from the WRONG server
19. `ClawStoreNotifications.installedSetChanged` fired every poll tick (P2) — must fire only on terminal transitions (installed / installedButBlocked / notInstalled / installFailed), not on every availability refresh
20. `AgentType` encoded as structured object instead of bare string (P0) — v3 readers on older builds would fail; `JSONEncoder().encode(.claw("x"))` MUST emit `"x"`, not `{"case":"claw","name":"x"}`
21. Logout of last server leaves main window behind Welcome (P1) — `AppDelegate.logout` must close ALL main windows before `openWelcomeWindow()` when `pairedServers.isEmpty`
22. `ServerContext` duplicated in iOS + SoyehtCore (P0) — iOS must use `typealias` to SoyehtCore; re-declaring as `struct` allows two incompatible types to silently coexist
23. ActivityKit leaking into SoyehtCore (P0) — ActivityKit is iOS-only; `ClawDeployMonitor` must indirect via `ClawDeployActivityManaging` protocol with `NoOpClawDeployActivityManager` default for macOS
24. Claw Store window observer leak + double-retain (P0) — **FIXED (2026-04-21, PR #9 review)**: `AppDelegate.showClawStore` used to discard the `NSWindow.willCloseNotification` token AND retain the controller twice (array + property). Now singleton property only, token stored in `clawStoreCloseObserver` and removed in callback. Zero dangling observers across open/close cycles
25. `soyeht start --network` flag not wired end-to-end (P0) — **Swift side FIXED** via `TheyOSEnvironment.cliSupportsNetworkFlag` probe + `TheyOSInstaller.buildStartArgs(mode:supportsNetworkFlag:)`; falls back silently on older taps. **Rust CLI work pending** in separate theyos-repo chat per `QA/handoffs/theyos-network-flag.md`. Covered by `TheyOSInstallerTests.test_buildStartArgs_*`
26. Install left orphan subprocesses on Welcome close (P1) — **FIXED**: `WelcomeWindowController` is now `NSWindowDelegate` and posts `WelcomeWindowNotifications.willClose` in `windowWillClose`; `LocalInstallView` observes it and calls `installer.cancel()`, which SIGTERMs the in-flight `brew` / `soyeht` child. Covered by `TheyOSInstallerTests.test_cancel_terminatesRunningChild`
27. Clipboard auto-paste of `theyos://` link (P1) — **FIXED**: `RemoteConnectView` no longer prefills `linkText` on appear. The conditional "Colar do clipboard" button still offers explicit paste. Addresses privacy concern flagged in PR #9 review
28. Claw Store window kept stale context after server switch (P1) — **FIXED**: `ClawStoreWindowController` observes `ClawStoreNotifications.activeServerChanged` and calls `self.close()` on switch; the user reopens and picks up the new context
29. `InstalledClawsProvider.refresh()` race (P2) — **FIXED**: `loadTask = nil` cleared synchronously on MainActor at end of body instead of via a deferred `Task{}` hop. Two sequential `refresh()` calls no longer collapse into one

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
| 2026-05-05 | **MCP Direct Validation ST-Q-MCPA-021..104** (41/48 tested; 7 SKIP agent/manual; 3 code fixes: agent validation, repeated-agent suffix, JSON crash) | 41/41 PASS | [report](runs/2026-05-05-mcpa-021-104/report.md) |
| 2026-05-05 | **MCP Fanout — Agent Race Panes** (9 tests: 3 agents × 3 batches; `newWorkspace` param added; BUG-01 Codex env) | 9/9 PASS | [report](runs/2026-05-05-mcp-fanout/report.md) |
| 2026-05-04 | **Soyeht MCP Automation** (MCP/CLI/agent workflows, shell/file intents, naming/input terminators, layout automation) | PASS | [report](runs/2026-05-04-soyeht-mcp-automation/report.md) |
| 2026-04-20 | **Gate Full** (feat/visual-polish — iOS smoke 8/8, macOS WPL hitTest+kbd shortcuts, unit tests 162+394 PASS, 1 cargo P2 pre-existing) | PASS WITH WARNINGS | [report](runs/2026-04-20-gate-full/gate-report.md) |
| 2026-04-20 | **WPL mouse drag fix** (WPL-056..063 — tab drag + window drag coexistence) | 3/8 PASS automated (native-devtools) / 5 PENDING manual — fix via opaque tab bg + `.mouseMoved` monitor | [report](runs/2026-04-20-wpl-mouse-drag/report.md) |
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
