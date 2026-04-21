---
id: mac-welcome-onboarding
ids: ST-Q-MWEL-001..014
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: true
cleanup_required: true
platform: macOS
---

# macOS Welcome Window + theyOS Auto-Install

## Objective
Verify the first-launch onboarding flow introduced on `feat/claw-store-macos`: `WelcomeWindowController` replaces the login sheet when `SessionStore.pairedServers.isEmpty`, offers two paths (install theyOS locally via Homebrew, or paste a `theyos://` link), and — after local install completes — auto-pairs the Mac against `localhost:8892` using the bootstrap token, opening the main window with the new server active. Logout of the last server returns the user to the Welcome window (Option A).

## Risk
- `AppDelegate.applicationDidFinishLaunching` still calls `openNewMainWindow()` before the empty-server check → main window flashes then Welcome window opens on top, confusing first-launch UX.
- `TheyOSInstaller` invokes `brew` from a PATH that doesn't include `/opt/homebrew/bin` → install fails silently with `executable not found`.
- Network mode radio (localhost vs Tailscale) is not wired to `soyeht start --network=<mode>` → theyOS starts in the wrong mode.
- `TheyOSHealthProber` polls `/health` before `soyeht start` actually binds the port → health check times out even though server is starting.
- `TheyOSAutoPairService` reads `~/.theyos/bootstrap-token` with the wrong file-protection / permission assumption → bootstrap step fails with permission denied.
- `POST /api/v1/mobile/pair-token` contract drifts → auto-pair appears to succeed but no session token is persisted.
- Logout of the **last** paired server doesn't close existing main windows before opening Welcome → user sees empty main window behind Welcome sheet.
- `RemoteConnectView` clipboard auto-detect fires on a URL from an unrelated app → security concern (don't silently prefill a token the user didn't paste).

## Preconditions
- Fresh macOS app build on `feat/claw-store-macos` (or merged)
- **For MWEL-001..007:** Homebrew NOT yet containing `soyeht/tap` (`brew tap soyeht/tap` must be fresh). If theyOS is already installed, run `brew uninstall theyos && brew untap soyeht/tap` and delete `~/.theyos/` first.
- **For MWEL-008..011:** A second Mac or server already running theyOS with a valid pair token (output of `soyeht pair` on that machine).
- No paired servers in SessionStore (delete app's keychain entries via `security delete-generic-password -s com.soyeht.mobile` if needed).

## How to automate
- **Install flow**: `mcp__XcodeBuildMCP__build_run_sim` for macOS target; `mcp__native-devtools__find_text "Install theyOS on this Mac"` → `click`; `find_text "localhost"` → `click`; `find_text "Install & start"` → `click`. Stream install logs via UI tail panel.
- **Remote link flow**: `pbcopy <<< "theyos://pair?token=X&host=Y"`; launch app → verify `RemoteConnectView` prefills automatically.
- **Health probe**: `curl -s http://localhost:8892/health` after install to confirm server is up before asserting auto-pair.
- **Pair contract**: Capture request with `mitmproxy` or inspect `~/.theyos/logs/` to confirm `POST /api/v1/mobile/pair-token` is sent with `Authorization: Bearer <bootstrap-token>`.
- **Logout → Welcome**: Invoke `File > Logout` (or equivalent) on the last server; assert main windows closed AND Welcome window visible via `mcp__native-devtools__list_windows`.

## Test Cases

### First launch — branching

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWEL-001 | Fresh install, no paired servers: launch app | **Welcome window** (640×540) appears. Main window does NOT flash before it. No login sheet anywhere | P0 | Yes |
| ST-Q-MWEL-002 | Welcome window visible: verify two cards | "Install theyOS on this Mac" and "Connect to existing server" both visible. No QR scanner, no third option | P1 | Yes |
| ST-Q-MWEL-003 | App launched with ≥1 paired server | Main window opens directly. Welcome window NOT shown | P0 | Yes |

### Install-on-this-Mac path (localhost)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWEL-004 | Click "Install theyOS on this Mac" | Sub-view with network-mode picker (localhost / Tailscale). Default = localhost. "Install & start" button | P1 | Yes |
| ST-Q-MWEL-005 | Keep localhost selected, click Install | Progress panel appears with live log tail. Phases advance: `brew tap` → `brew install theyos` → `soyeht start` → `health probe` → `auto-pair`. No terminal window or shell command shown to user | P0 | Assisted |
| ST-Q-MWEL-006 | Wait for install to finish | Welcome window dismisses. Main window opens with localhost server active. Instance list loads (empty, since fresh install) | P0 | Assisted |
| ST-Q-MWEL-007 | Verify theyOS is running | `curl http://localhost:8892/health` returns 200. `~/.theyos/bootstrap-token` exists. Mac is listed as paired under File menu | P0 | Assisted |

### Install-on-this-Mac path (Tailscale)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWEL-008 | Click "Install theyOS on this Mac", switch picker to Tailscale | If Tailscale not detected on machine: picker shows inline explainer + disabled confirm. If Tailscale present: confirm enabled | P1 | Assisted |
| ST-Q-MWEL-009 | With Tailscale installed, proceed with install | `soyeht start --network=tailscale` is invoked. Health probe targets the Tailscale hostname (not localhost). Auto-pair succeeds via Tailscale host | P1 | Manual |

### Connect-to-existing-server path

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWEL-010 | With `theyos://pair?token=X&host=Y` on clipboard, launch app | Welcome window opens. "Connect to existing server" card shows a hint that a link was detected. Paste field is pre-filled with the clipboard URL | P1 | Yes |
| ST-Q-MWEL-011 | Click "Connect" on prefilled link | `SoyehtAPIClient.pairServer(token:host:)` is called. Server is added to SessionStore. Welcome dismisses. Main window opens | P0 | Assisted |
| ST-Q-MWEL-012 | Paste an **invalid** link (malformed token) → click Connect | Inline error shown under paste field. Welcome window stays open. No crash, no partial SessionStore write | P1 | Yes |

### Logout → return to Welcome (Option A)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWEL-013 | With exactly ONE paired server: File > Logout | Main window(s) close. Welcome window opens. SessionStore is empty. Relaunching app would show Welcome again | P1 | Assisted |
| ST-Q-MWEL-014 | With TWO paired servers: logout from the active one | Main window stays open with the remaining server selected. Welcome window is NOT shown. Logged-out server removed from paired list | P1 | Assisted |

## New a11y identifiers (native-devtools locators)

- `soyeht.welcome.window`
- `soyeht.welcome.card.installLocal`
- `soyeht.welcome.card.connectRemote`
- `soyeht.welcome.install.mode.localhost`
- `soyeht.welcome.install.mode.tailscale`
- `soyeht.welcome.install.confirmButton`
- `soyeht.welcome.install.progressPanel`
- `soyeht.welcome.install.logTail`
- `soyeht.welcome.remote.pasteField`
- `soyeht.welcome.remote.connectButton`
- `soyeht.welcome.remote.errorLabel`

## Cleanup
- If MWEL-005/006 was run on a machine where theyOS was not previously installed, the user may want to keep it — if not, `brew uninstall theyos && brew untap soyeht/tap && rm -rf ~/.theyos` to reset.
- Remove any `test-qa-*` paired entries via File > Logout per server.
- If MWEL-009 toggled Tailscale mode, restart theyOS in localhost mode if that was the pre-test state.

## Out of Scope
- Installer error recovery (brew unreachable, port 8892 already in use): see separate hardening pass.
- Firewall / codesign dialogs from macOS Gatekeeper on first Homebrew install: behavior is macOS-native, not app-owned.
- Multi-server add from Welcome (current UX: add second server is from File menu, not Welcome).

## Related code
- `TerminalApp/SoyehtMac/AppDelegate.swift` — branching on `SessionStore.pairedServers.isEmpty`, `openWelcomeWindow()`, `finishWelcome()`, logout handling
- `TerminalApp/SoyehtMac/Welcome/WelcomeWindowController.swift` — NSWindowController host
- `TerminalApp/SoyehtMac/Welcome/WelcomeRootView.swift` — two-card SwiftUI root
- `TerminalApp/SoyehtMac/Welcome/LocalInstallView.swift` — mode picker + install progress panel
- `TerminalApp/SoyehtMac/Welcome/RemoteConnectView.swift` — paste + clipboard auto-detect
- `TerminalApp/SoyehtMac/Welcome/TheyOSInstaller.swift` — brew Process orchestration, phases
- `TerminalApp/SoyehtMac/Welcome/TheyOSHealthProber.swift` — polls `/health` before declaring ready
- `TerminalApp/SoyehtMac/Welcome/TheyOSAutoPairService.swift` — bootstrap-token → `/mobile/pair-token` → `pairServer`
- `TerminalApp/SoyehtMac/Welcome/TheyOSEnvironment.swift` — paths, brew candidates, Tailscale detection
