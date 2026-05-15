---
id: mac-pane-claws-integration
ids: ST-Q-MPCI-001..018
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Pane ↔ Installed Claws Integration

## Objective
Verify the Fase 4/5 wiring between the macOS pane system and the Claw Store: `EmptyPaneSessionPickerView` no longer renders a hardcoded `[.shell, .claude, .codex, .hermes]` list, but instead consumes `InstalledClawsProvider.agentOrder` (shell + every currently-installed claw, ordered by name). The picker exposes a "Open Claw Store" row that opens `ClawStoreWindowController` via the `onOpenClawStore` callback. When a user installs or uninstalls a claw in the Store (or via any other device), every open pane picker updates live without requiring the user to reopen the pane, driven by `NotificationCenter` → `ClawStoreNotifications.installedSetChanged` → `InstalledClawsProvider.refresh()`.

## Risk
- `InstalledClawsProvider.claws` empty on first open → picker shows ONLY shell, user cannot launch any claw even when several are installed.
- `InstalledClawsProvider` loads on main actor but refresh fires from background notification → SwiftUI publishes from wrong thread.
- Provider never calls `refresh()` after a successful install → picker stays stale until the pane is destroyed and recreated.
- `onOpenClawStore` callback not wired in `PaneViewController` → clicking the Store row silently does nothing.
- `PaneViewController` routes on `.shell` vs `default` instead of `.shell` vs `.claw(_)` after the AgentType reshape → custom claws fall through to the shell PTY path instead of opening the session config dialog.
- `SessionConfigDialogView` still defaults to `.claude` (legacy) instead of `.claw("claude")` → config sheet writes a malformed Conversation.
- Provider retains `NSObjectProtocol` observer but never removes it → memory leak + zombie callbacks after window close.
- Multiple Mac windows each instantiate a separate `InstalledClawsProvider` → notification fan-out duplicates refresh() calls and hits rate-limit.
- `agentOrder` returns `AgentType.canonicalCases` until `hasLoaded == true`, but the first `refresh()` errors and `hasLoaded` is set to `true` anyway → picker silently shows only shell with no "Install a Claw" affordance (make sure empty list → still show Store row).

## Preconditions
- macOS app launched, ≥1 paired server active
- Server backend: at least 2 different claws installed, ≥1 claw NOT installed (so install tests have something to install)
- At least one workspace with at least one empty pane visible, OR ability to split a pane to produce an empty pane

## How to automate
- **Initial picker state**: `split_pane` or open new workspace; count rows via `mcp__native-devtools__take_ax_snapshot`; assert count == installed claws + 1 (shell) + 1 (Store row).
- **Open Store from picker**: `find_text "Open Claw Store"` → `click`; assert Claw Store window appears via `list_windows`.
- **Cross-window sync**: Open pane picker in window A; install a claw in Claw Store (window B); without touching pane A, take another snapshot → assert new claw row is present.
- **Provider refresh**: Attach to Claw Store window, install a claw, then query `InstalledClawsProvider.shared.claws.count` via a debug build hook (optional — for unit-level coverage rely on `ClawStoreViewModel`/`ClawDetailViewModel` notification tests).
- **No leaks**: Open and close 10 panes in sequence; confirm `InstalledClawsProvider.shared` still has exactly one observer registered (inspect `NotificationCenter` via debugger or rely on `deinit` breakpoint count).

## Test Cases

### Picker initial load

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MPCI-001 | Open an empty pane picker (fresh app launch, first picker open) | Rows shown: `shell`, every installed claw by name, then "Open Claw Store" row at the bottom. No legacy `claude/codex/hermes` rows if those aren't installed | P0 | Yes |
| ST-Q-MPCI-002 | Open picker BEFORE `InstalledClawsProvider` has finished first load | Picker shows fallback `AgentType.canonicalCases` (shell + claude/codex/hermes). Store row still visible. No blank picker, no spinner blocking input | P1 | Yes |
| ST-Q-MPCI-003 | Server returns empty installed claws array | Picker shows ONLY `shell` + "Open Claw Store" row. No crash, no duplicate shell row | P1 | Yes |
| ST-Q-MPCI-004 | Claw name sort order (install "picoclaw", "alpha", "zeta") | Rows appear in order: shell, alpha, picoclaw, zeta, [Store]. Case-insensitive, stable | P2 | Yes |

### Selecting a row

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MPCI-005 | Click `shell` row | Local PTY spawns. No session config dialog. Pane becomes active | P0 | Yes |
| ST-Q-MPCI-006 | Click a `.claw(name)` row | Session config dialog opens. Conversation draft has `agent = .claw(name)`. `commander = .mirror(instanceID:)` after instance chosen | P0 | Yes |
| ST-Q-MPCI-007 | Start session from `.claw(name)` dialog | App auto-selects the first online instance whose `clawType == name`. No cross-claw contamination — `.claw("codex")` never connects to a non-codex container. If no matching instance exists, `surfaceNoInstancesAlert` is shown instead of connecting silently to the wrong claw | P1 | Assisted |
| ST-Q-MPCI-008 | Click "Open Claw Store" row | `ClawStoreWindowController` opens. Pane picker is dismissed (or stays; both acceptable as long as both windows are visible). No crash | P1 | Yes |
| ST-Q-MPCI-009 | With NO server paired: Store row is hidden OR disabled | Do not offer an entrypoint that would crash gate in `AppDelegate.showClawStore` | P2 | Yes |

### Live sync after install / uninstall

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MPCI-010 | Open empty pane picker in window A. Install a new claw via Store window B. Wait for install to finish. Then create an instance of the newly installed claw via Deploy flow | `ClawStoreNotifications.installedSetChanged` is posted and `InstalledClawsProvider` refreshes automatically (no manual refresh needed). The new claw row only appears in the picker **after an online instance exists** — `InstalledClawsProvider` intentionally filters to claws with running instances (nothing to connect to otherwise). Verify: (1) notification fires, (2) after instance is online, picker gains the new claw row | P1 | Assisted |
| ST-Q-MPCI-011 | Uninstall a claw via Store. Open pane picker | Uninstalled claw is no longer listed. Any pane already running that claw is NOT force-closed | P1 | Assisted |
| ST-Q-MPCI-012 | Multi-server: install a claw on server B while window shows server A context | Picker does NOT add claws from server B when server A is active. Switching to server B's context triggers `InstalledClawsProvider.refresh()` via session change → rows update | P1 | Assisted |
| ST-Q-MPCI-013 | While pane picker is open, server goes offline mid-install | Picker freezes on last-known-good state (no spinning forever). When server recovers, next notification refreshes the list | P2 | Manual |

### Provider lifecycle / leaks

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MPCI-014 | Open and close 10 panes in a row | `InstalledClawsProvider.shared` has exactly ONE observer registered for `ClawStoreNotifications.installedSetChanged`. No leaked NSObjectProtocol subscribers | P2 | Manual |
| ST-Q-MPCI-015 | Kill backend connection. Trigger `installedSetChanged` manually. Wait 5s. Reconnect. Post another notification | Provider recovers — second notification produces a successful refresh. `hasLoaded` remains true. No duplicate in-flight load tasks | P2 | Manual |
| ST-Q-MPCI-016 | Cold launch: does `InstalledClawsProvider` load on first access only, or eagerly at app start? | Lazy: first `shared` access triggers load. No network call at AppDelegate startup that would delay Welcome window | P1 | Yes |

### AgentType round-trip via picker

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MPCI-017 | Pick `.claw("codex")`, create Conversation, quit app, relaunch, reopen the same workspace | Conversation round-trips cleanly. `agent == .claw("codex")`. Pane resumes mirror mode to the same instance. No decode error on `Conversation` | P0 | Assisted |
| ST-Q-MPCI-018 | Workspace saved under v3 (before this branch): open in v4 build | Migration decodes `"claude"` → `.claw("claude")`. Pane picker lists installed claws alongside the restored conversation. No data loss | P0 | Yes — see mac-agent-type-migration.md |

## New a11y identifiers

- `soyeht.pane.emptyPicker.row.shell`
- `soyeht.pane.emptyPicker.row.claw.{name}`
- `soyeht.pane.emptyPicker.row.openStore`

## Out of Scope
- `NewConversationSheetController` dynamic claw list (currently still uses `AgentType.canonicalCases` — tracked as a follow-up, not in this gate).
- Claw instance ordering inside `InstancePicker` (relies on `getInstances` sort order, tested in `instance-list-actions.md`).
- Claw Store invocation from the dock menu / global hotkey (not implemented).

## Related code
- `TerminalApp/SoyehtMac/ClawStore/InstalledClawsProvider.swift` — shared cache + notification observer
- `TerminalApp/SoyehtMac/PaneGrid/EmptyPaneSessionPickerView.swift` — dynamic rows via `InstalledClawsProvider`, Store row at bottom, `onOpenClawStore` callback, `ClawStoreRowButton`
- `TerminalApp/SoyehtMac/PaneGrid/PaneViewController.swift` — wires `emptyPicker.onOpenClawStore = AppDelegate.showClawStore(nil)`, routes `.shell` vs `.claw(_)`
- `TerminalApp/SoyehtMac/PaneGrid/SessionConfigDialogView.swift` — default `.claw("claude")`, per-claw instance filtering
- `TerminalApp/SoyehtMac/Model/AgentType.swift` — `.shell | .claw(String)`, `canonicalCases`
- `TerminalApp/SoyehtMac/Model/Conversation.swift` — unchanged structurally; `agent: AgentType`, `commander: CommanderState`
- `Packages/SoyehtCore/.../ClawStore/ClawNotificationHelper.swift` — `ClawStoreNotifications.installedSetChanged`
- `Packages/SoyehtCore/.../ClawStore/ClawStoreViewModel.swift` — posts notification when polling reaches terminal
- `Packages/SoyehtCore/.../ClawStore/ClawDetailViewModel.swift` — posts notification when polling reaches terminal
