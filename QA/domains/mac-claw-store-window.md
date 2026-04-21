---
id: mac-claw-store-window
ids: ST-Q-MCSW-001..016
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: true
cleanup_required: true
platform: macOS
---

# macOS Claw Store Window

## PR #9 review fixes (2026-04-21)

- **MCSW-014 / risk "window closes mid-poll"** — `ClawStoreViewModel.deinit` already cancels `pollingTask`, and the task auto-cancels when `!hasTransientClaws`. Confirmed as mitigated in review; no code change needed for this risk, only the observer hygiene below.
- **NEW risk fixed: observer leak in `AppDelegate.showClawStore`** — the `NSWindow.willCloseNotification` token was discarded AND the WC was retained twice (array + property). Now the Claw Store is a singleton window: single strong reference via `clawStoreWindowController`, observer token stored in `clawStoreCloseObserver` and removed in the close callback. Zero dangling observers across open/close cycles.
- **NEW risk fixed: server switch leaks stale context** — `ClawStoreWindowController` now observes `ClawStoreNotifications.activeServerChanged` and calls `self.close()` on switch. User reopens and picks up the new context. Prevents the Store from silently querying the previous server.

## Objective
Verify the native macOS Claw Store window introduced on `feat/claw-store-macos`: `ClawStoreWindowController` (NSWindow 840×620) hosts `MacClawStoreRootView` via `NSHostingController`, driven by the SoyehtCore-shared `ClawStoreViewModel`/`ClawDetailViewModel`. The window is reachable via menu `Soyeht → Claw Store` (⌘⌥S). Browse → detail → install/uninstall → setup(deploy) flows must work against a real server scoped by `SessionStore.currentContext()`. The window refuses to open when no server is paired.

## Risk
- `ClawStoreWindowController` opened before any server is paired → ViewModel constructed with a `ServerContext` that is nil-unwrap-crashing.
- `NSHostingController` + `NavigationStack` quirks on macOS 15: pushing a detail view and dismissing via toolbar leaves a dangling frame.
- `InstalledClawsProvider.refresh()` is not triggered after install completes → other UI (pane picker) lags behind the Store window.
- Install action runs on the wrong actor → SwiftUI `@Published` updates crash with "publishing from background thread".
- `MacClawSetupView` sends `disk_gb` on macOS targets where the backend expects it omitted (see claw-store-deploy.md risks for shared contract).
- The window closes while install polling is active → `ClawStoreViewModel.pollingTask` leaks or continues writing to a detached view.

## Preconditions
- macOS app launched, at least one paired server with admin context
- Server backend has ≥1 installed claw and ≥1 uninstalled claw available
- For uninstall tests: at least one installed claw that is safe to uninstall (prefer a non-default one)

## How to automate
- **Open window**: `mcp__XcodeBuildMCP__key_press` ⌘⌥S. Assert window exists via `mcp__native-devtools__list_windows`.
- **Browse → detail**: `find_text "<claw name>"` → `click`. Verify detail visible via `find_text "Install"` or `"Deploy"`.
- **Install**: click Install button, monitor `soyeht.clawDetail.progressBar` accessible element value polling.
- **Setup flow**: click "Deploy" → assert Form visible with steppers; type into `username` field; click "Deploy instance".
- **Cross-window sync**: Open Claw Store, install a claw, THEN open an empty pane — verify newly installed claw appears in pane picker (covered in mac-pane-claws-integration.md).

## Test Cases

### Window open / gated

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCSW-001 | With paired server: press ⌘⌥S | Claw Store window opens (minWidth 680, minHeight 520 — SwiftUI constrains; NSWindow init is 840×620 but SwiftUI fitting size wins). Title = "Claw Store". Menu item Soyeht → Claw Store is enabled | P0 | Yes |
| ST-Q-MCSW-002 | With NO paired server: press ⌘⌥S | Menu item is DISABLED. Window does NOT open. No crash. No log spew | P1 | Yes |
| ST-Q-MCSW-003 | Open Claw Store twice (⌘⌥S, switch to another window, ⌘⌥S again) | Existing Claw Store window is brought to front. A second instance is NOT created | P2 | Yes |

### Browse (catalog load)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCSW-004 | Fresh open: observe grid | LazyVGrid of claw cards renders. Each card shows name, short description, install-state badge | P1 | Yes |
| ST-Q-MCSW-005 | Scroll grid | No jank. Cards are memoized — scrolling up then down does not re-request the catalog | P2 | Assisted |
| ST-Q-MCSW-006 | Server returns empty catalog | Placeholder empty state visible (not a blank window). No infinite spinner | P2 | Yes |
| ST-Q-MCSW-007 | Server returns 500 | Error banner at top of window. "Retry" button visible. No crash | P1 | Assisted |

### Detail view

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCSW-008 | Click a claw card | Detail view pushes via NavigationStack. Hero section, install-state banner, description, CTAs visible | P1 | Yes |
| ST-Q-MCSW-009 | Detail view for `.installed` claw | Shows "Deploy" (primary) and "Uninstall" (destructive) buttons. No "Install" button | P1 | Yes |
| ST-Q-MCSW-010 | Detail view for `.installedButBlocked` claw | Shows "Uninstall" ONLY. No "Deploy" button. Reasons block visible | P1 | Assisted |
| ST-Q-MCSW-011 | Back button on detail view | Returns to grid. Scroll position preserved | P2 | Yes |

### Install / uninstall

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCSW-012 | Click Install on uninstalled claw in detail view | Button switches to progress state. Progress bar animates. `ClawStoreViewModel.isPolling == true`. No UI freeze | P1 | Yes |
| ST-Q-MCSW-013 | Wait for install to finish | Detail view updates to `.installed` branch. `ClawStoreNotifications.installedSetChanged` is posted. macOS user notification fires | P1 | Assisted |
| ST-Q-MCSW-014 | Click Uninstall on installed claw | State transitions to `.uninstalling`. Polling continues until `.notInstalled` is reached. Back-navigating during polling does NOT cancel the transition | P1 | Assisted |

### Setup (deploy) flow

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCSW-015 | Click Deploy on `.installed` claw | `MacClawSetupView` opens (Form with CPU/RAM/disk steppers, username picker). Initial values come from `resource-options` | P1 | Yes |
| ST-Q-MCSW-016 | Submit a valid form | Request is sent to backend. Window returns to detail view. New instance appears in InstanceList (verified via main window). No error banner | P1 | Assisted |

## New a11y identifiers

- `soyeht.macClawStore.window`
- `soyeht.macClawStore.grid`
- `soyeht.macClawStore.card.{name}`
- `soyeht.macClawStore.card.{name}.stateBadge`
- `soyeht.macClawStore.emptyState`
- `soyeht.macClawStore.errorBanner`
- `soyeht.macClawDetail.installButton`
- `soyeht.macClawDetail.uninstallButton`
- `soyeht.macClawDetail.deployButton`
- `soyeht.macClawDetail.progressBar`
- `soyeht.macClawSetup.cpuStepper`
- `soyeht.macClawSetup.ramStepper`
- `soyeht.macClawSetup.diskStepper`
- `soyeht.macClawSetup.usernamePicker`
- `soyeht.macClawSetup.submitButton`

## Cleanup
- Uninstall any claw installed purely for MCSW-012/013.
- Delete any `test-qa-*` instance created during MCSW-016.
- If MCSW-014 was aborted mid-uninstall: wait for backend to reach terminal state before closing the window (backend uninstall cannot be cancelled from client).

## Out of Scope
- iOS Claw Store parity (covered in `claw-store-deploy.md`).
- Live Activity on macOS (macOS uses `NoOpClawDeployActivityManager` — no Live Activity support).
- Claw search / filter UI (not yet implemented).

## Related code
- `TerminalApp/SoyehtMac/ClawStore/ClawStoreWindowController.swift` — NSWindow host, ⌘⌥S wiring
- `TerminalApp/SoyehtMac/ClawStore/MacClawStoreRootView.swift` — NavigationStack + grid
- `TerminalApp/SoyehtMac/ClawStore/MacClawCardView.swift` — card cell with state-aware border
- `TerminalApp/SoyehtMac/ClawStore/MacClawDetailView.swift` — detail + CTAs + progress
- `TerminalApp/SoyehtMac/ClawStore/MacClawSetupView.swift` — deploy Form
- `TerminalApp/SoyehtMac/ClawStore/MacClawStoreTheme.swift` — SwiftUI color tokens
- `TerminalApp/SoyehtMac/AppDelegate.swift` — `installClawStoreMenu()`, `showClawStore(_:)` gated on `SessionStore.currentContext()`
- `Packages/SoyehtCore/.../ClawStore/ClawStoreViewModel.swift` — shared ViewModel (see also claw-store-deploy.md)
