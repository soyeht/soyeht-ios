---
id: mac-claw-drawer
ids: ST-Q-MCDR-001..018
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: true
cleanup_required: true
platform: macOS
---

# macOS Claw Drawer (ClawDrawerViewController)

## Objective
Verify the sidebar drawer that surfaces from the workspace pane picker, implemented in `ClawDrawerViewController`. The drawer hosts four routes: `.claws` (installed-claw list), `.store` (compact claw catalog), `.installMac` / `.connectServer` (setup paths for machines without theyOS), and `.uninstallTheyOS` (full removal pipeline via `TheyOSUninstaller`). This is distinct from the dedicated Claw Store window (`mac-claw-store-window.md`) — these test cases cover only the drawer surface.

## Risk
- Drawer opens on a stale server context after a server switch → claw list shows claws from the wrong server.
- `CompactClawStoreRow.canInstall` gate broken → Install button appears on an already-installed claw, and the API call 409s silently.
- `ClawStoreNotifications.installedSetChanged` not observed by the drawer → installed claw list never refreshes after install succeeds.
- `LocalInstallView(compact: true)` intrinsic height leaks into the AppKit window via `NSHostingController` → window resizes unexpectedly when the user navigates to `.installMac`.
- `TheyOSUninstaller` best-effort pipeline swallows errors per-step → phase transitions to `.done` even though critical steps (e.g., `brew uninstall`) failed, and `residualHint` is never shown.
- Root-owned VM image files (`~/Library/Application Support/theyos/vms/macos-base`) cause `sweepResidualDirectories` to silently omit them from `failedPaths` → `residualHint` is nil but files remain.
- Cancel during `TheyOSUninstaller.runUninstall` leaves a partially-cleared SessionStore (some servers removed, others not) if cancellation races with the `.clearingAppState` phase.

## Preconditions
- SoyehtMac running on `feat/claw-store-macos` (or merged).
- At least one theyOS server paired and active (so the claw list is meaningful).
- **For MCDR-011..018 (uninstall flow):** theyOS installed via Homebrew. Run on a machine where wiping theyOS is acceptable or use a VM / CI Mac.

## How to automate
- **Open drawer**: `mcp__native-devtools__find_text "claw store…"` → `click`; `mcp__native-devtools__list_windows` to confirm drawer window opened.
- **Store navigation**: `find_text "Store"` → `click`; iterate `find_text "<claw-name>"` to locate target row.
- **Install**: `find_text "Install"` (within row bounds) → `click`; poll `find_text "Installing"` until gone; assert `find_text "Installed"`.
- **Uninstall entry**: `find_text "Uninstall theyOS"` → `click`; assert `find_text "Remove theyOS"` heading visible.
- **Confirm uninstall**: `find_text "Uninstall"` (amber button) → `click`; tail log via `find_text "brew services stop"`.
- **Post-uninstall**: `security find-generic-password -s com.soyeht.mobile` must return error (no keychain entry); `ls /opt/homebrew/Cellar/theyos` must fail.

## Test Cases

### Drawer open + initial state

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCDR-001 | Main workspace visible: click pane-picker "claw store…" button | Drawer opens as a separate floating panel anchored to the workspace window | P0 | Yes |
| ST-Q-MCDR-002 | Drawer just opened | Initial route is `.claws` — shows list of claws installed on the active server. No catalog visible by default | P1 | Yes |

### Store catalog + install

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCDR-003 | Navigate to Store route (via button or clicking a claw row) | `CompactClawStoreRow` renders each claw. Rows in `notInstalled` or `installFailed` states show an "Install" button; `installed` / `installing` rows do NOT | P0 | Yes |
| ST-Q-MCDR-004 | Click "Install" on a `notInstalled` claw | Row immediately transitions to "Installing…" spinner. API call fires to `POST /api/v1/mobile/claws/{name}/install` | P0 | Yes |
| ST-Q-MCDR-005 | Install API returns 200 (success) | Row transitions to `installed` state (Install button gone). `ClawStoreNotifications.installedSetChanged` fires → claws list on the `.claws` route refreshes | P0 | Assisted |
| ST-Q-MCDR-006 | Install API returns 4xx / network error | Row transitions to `installFailed` state. Error copy visible. Retry possible (clicking Install again re-fires the request) | P1 | Assisted |

### Setup routes (no server configured)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCDR-007 | Drawer visible with a macOS server active: check store for "Install theyOS on this Mac" entry | Entry is visible in the store or claws list as a setup CTA | P1 | Yes |
| ST-Q-MCDR-008 | Click "Install theyOS on this Mac" entry | Navigates to `.installMac` — renders `LocalInstallView(compact: true, skipBrew: false)`. Mode picker visible. AppKit window does NOT resize | P1 | Yes |
| ST-Q-MCDR-009 | Click "Connect to a server" entry | Navigates to `.connectServer` — renders `RemoteConnectView(compact: true)`. Paste field visible | P1 | Yes |

### Uninstall theyOS route

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCDR-010 | Claws list visible: locate "Uninstall theyOS…" text-link at the bottom | Link is present but visually de-emphasized (not a primary button). Clicking it navigates to `.uninstallTheyOS` | P1 | Yes |
| ST-Q-MCDR-011 | `.uninstallTheyOS` route visible | Shows `UninstallTheyOSView(compact: true)`: amber warning card with 4 bullet points (VMs, data, servers, brew formula). Amber "Uninstall" confirm button. No network-mode picker | P0 | Yes |
| ST-Q-MCDR-012 | Navigate back from UninstallTheyOSView before confirming | Returns to claws list. Nothing was uninstalled. `TheyOSUninstaller` was never invoked | P1 | Yes |
| ST-Q-MCDR-013 | Click "Uninstall" confirm button | Progress panel appears. Phase sequence advances: `preparing` → `stoppingService` → `purgingData` → `uninstallingFormula` → `untapping` → `clearingAppState` → `done`. Log tail streams subprocess output | P0 | Assisted |
| ST-Q-MCDR-014 | Uninstall reaches `.done` phase | "Dismiss" button appears. Clicking it calls `onCompleted`. SessionStore is empty; all paired server keychain tokens removed; `ls /opt/homebrew/Cellar/theyos` returns "No such file" | P0 | Assisted |
| ST-Q-MCDR-015 | Root-owned VM image files present (e.g., `~/Library/Application Support/theyos/vms/macos-base` owned by root) | After pipeline ends, `residualHint` panel is shown in amber with `sudo rm -rf` recipe. Phase still reaches `.done` (best-effort — not `.failed`) | P1 | Assisted |
| ST-Q-MCDR-016 | Click drawer's back button / close mid-uninstall while `brew uninstall` subprocess is running | Subprocess receives SIGTERM. Uninstaller phase transitions to `.failed(cancelled)`. No orphan `brew` processes remain | P1 | Assisted |

### Cross-session correctness

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MCDR-017 | Drawer claw list loaded for server A; user switches active server to B without closing drawer | Claw list refreshes to show claws for server B. No stale entries from server A remain | P1 | Assisted |
| ST-Q-MCDR-018 | Install a claw while the Claw Store window (⌘⌥S) is also open | Both the drawer row and the Claw Store window row update to `installed` state after `ClawStoreNotifications.installedSetChanged` fires. No duplicate API call | P2 | Assisted |

## New a11y identifiers (native-devtools locators)

- `soyeht.clawDrawer.window`
- `soyeht.clawDrawer.route.claws`
- `soyeht.clawDrawer.route.store`
- `soyeht.clawDrawer.route.installMac`
- `soyeht.clawDrawer.route.connectServer`
- `soyeht.clawDrawer.route.uninstallTheyOS`
- `soyeht.clawDrawer.uninstallEntry` (text-link at bottom of claws list)
- `soyeht.uninstall.confirmButton`
- `soyeht.uninstall.progressPanel`
- `soyeht.uninstall.residualHint`
- `soyeht.uninstall.dismissButton`

## Cleanup
- If MCDR-013/014 ran on a machine where theyOS should be retained: reinstall via Welcome flow.
- Remove any `test-qa-*` paired entries via File > Logout per server.
- Kill orphan processes: `pkill -f soyeht-server && pkill -f brew`.

## Out of Scope
- Claw Store dedicated window (⌘⌥S): see `mac-claw-store-window.md`.
- Claw install error recovery beyond the drawer surface (backend-side rate limiting, deploy queue): see `claw-store-deploy.md`.
- theyOS installer error recovery within the drawer's `.installMac` route: see `mac-theyos-installer-contract.md`.

## Related code
- `TerminalApp/SoyehtMac/ClawStore/ClawDrawerViewController.swift` — drawer NSViewController + SwiftUI host; routes enum; `ClawDrawerViewModel`; `CompactClawStoreRow`; `uninstallTheyOSEntryButton`
- `TerminalApp/SoyehtMac/Welcome/UninstallTheyOSView.swift` — SwiftUI confirmation + progress panel (`compact: true` in drawer)
- `TerminalApp/SoyehtMac/Welcome/TheyOSUninstaller.swift` — subprocess pipeline, `TheyOSUninstallPhase`, best-effort steps, `residualHint`
- `TerminalApp/SoyehtMac/Welcome/LocalInstallView.swift` — reused for `.installMac` route (`compact: true`)
- `TerminalApp/SoyehtMac/Welcome/RemoteConnectView.swift` — reused for `.connectServer` route
- `Packages/SoyehtCore/.../SessionStore.swift` — `removeServer(id:)`, `clearSession()` called by uninstaller
