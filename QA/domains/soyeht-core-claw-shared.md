---
id: soyeht-core-claw-shared
ids: ST-Q-SCCS-001..016
profile: standard
automation: auto
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: shared
---

# SoyehtCore Shared Claw Types (Fase 1)

## Objective
Pin the contract of the Claw types that were promoted from `TerminalApp/Soyeht/ClawStore/*` (iOS-only `internal`) to `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/*` (cross-platform `public`) on `feat/claw-store-macos`. These types must (1) compile and link into both the iOS app and the macOS app without duplication, (2) present a stable public API for `ClawStoreViewModel` / `ClawDetailViewModel` / `ClawSetupViewModel` consumers, and (3) keep existing iOS tests green since tests now import via `SoyehtCore` instead of `@testable import Soyeht`.

## Risk
- Any type (`Claw`, `ClawAvailability`, `OverallState`, `ClawRoute`, `ClawMockData.*`) accidentally revert to `internal` → macOS SPM link fails with "cannot find X in scope".
- `ClawDeployMonitor` pulls `ActivityKit` symbols into SoyehtCore → SPM package no longer compiles on macOS (ActivityKit is iOS-only). Must go through the `ClawDeployActivityManaging` protocol with `NoOpClawDeployActivityManager` on macOS.
- Duplicate type declarations remain in both locations → two `Claw` types coexist and SwiftUI views using `import SoyehtCore` fail with "ambiguous use".
- `SoyehtAPIClient+Claws.swift` moved to SoyehtCore but a legacy copy remains in `TerminalApp/Soyeht/` → iOS build picks the older iOS variant silently.
- `UnavailReason` in iOS `SoyehtAPIClient` was duplicated then removed → iOS file must now `import SoyehtCore` at the top. Removing that import breaks iOS build.
- `ServerContext` coexists as iOS typealias to `SoyehtCore.ServerContext` (see `soyeht-core-session-parity.md`). A code path constructing iOS-local `ServerContext` after the typealias collapse would be a compile error.
- `@testable import Soyeht` in `ClawViewModelTests` / `ClawAPITests` no longer exposes the shared types (they're `public` now, imported via `import SoyehtCore`). Tests that relied on `internal` helpers must migrate.
- `ClawNotificationHelper` uses `UNUserNotificationCenter` — available on iOS 10+ and macOS 10.14+. Any API call that is iOS-only (e.g., `UIApplication`-dependent) would break the SPM macOS target.

## Preconditions
- Clean clone of `feat/claw-store-macos` branch
- Xcode 16+, Swift 6 mode available
- SoyehtCore SPM package resolvable by both `TerminalApp/Soyeht.xcodeproj` (iOS) and `TerminalApp/SoyehtMac.xcodeproj` (macOS)

## How to automate
- **Build matrix**:
  ```
  xcodebuild -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
  xcodebuild -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac \
    -destination 'platform=macOS' build
  cd Packages/SoyehtCore && swift build
  ```
- **Test matrix**:
  ```
  xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
  cd TerminalApp/SoyehtMacTests && swift test
  ```
- **Duplication guard**: `rg -l "^(public |internal |final )?(struct|class|enum) Claw" TerminalApp/Soyeht/ClawStore/` must return an EMPTY list — every Claw type should live only under `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/`.
- **No ActivityKit in SoyehtCore**: `rg "import ActivityKit" Packages/SoyehtCore/` must return ZERO matches.

## Test Cases

### Build & link (platform matrix)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCCS-001 | `swift build` inside `Packages/SoyehtCore` | Succeeds on macOS host (no ActivityKit / no UIKit imports) | P0 | Yes |
| ST-Q-SCCS-002 | `xcodebuild build` for iOS simulator target | Succeeds. No "ambiguous use of" or "duplicate symbol" diagnostics for any Claw type | P0 | Yes |
| ST-Q-SCCS-003 | `xcodebuild build` for macOS target | Succeeds. `MacClawStoreRootView` and friends resolve Claw types via SoyehtCore | P0 | Yes |
| ST-Q-SCCS-004 | Grep for duplicate `struct Claw` declarations | Only one declaration exists, in `Packages/SoyehtCore/.../ClawStore/ClawModels.swift`. Zero hits under `TerminalApp/Soyeht/ClawStore/` | P0 | Yes |
| ST-Q-SCCS-005 | Grep `import ActivityKit` inside `Packages/SoyehtCore/` | Zero matches. ActivityKit stays iOS-only via protocol indirection | P0 | Yes |

### Public API surface

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCCS-006 | From a new Swift file that `import SoyehtCore`, instantiate `Claw`, `ClawAvailability`, `ClawStoreViewModel`, `ClawDetailViewModel`, `ClawSetupViewModel` | All compile. Each has a `public init` reachable from outside the package | P0 | Yes |
| ST-Q-SCCS-007 | ViewModels accept a `SoyehtCore.ServerContext` via init | Yes, not an iOS-local `ServerContext` (which is now a typealias anyway) | P1 | Yes |
| ST-Q-SCCS-008 | `ClawDeployMonitor` exposes `activityManagerProvider` closure | Closure is `public`, returns `ClawDeployActivityManaging`. iOS wires it in `AppDelegate` to `{ ClawDeployActivityManager() }`. macOS leaves default (NoOp) | P1 | Yes |
| ST-Q-SCCS-009 | `ClawStoreNotifications.installedSetChanged` is a public `Notification.Name` | Accessible from macOS code (e.g., `InstalledClawsProvider`) via `import SoyehtCore` | P1 | Yes |

### Tests migrated (no `@testable import Soyeht` regressions)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCCS-010 | Run `ClawViewModelTests` (iOS) | Passes. Imports `SoyehtCore` (not `@testable import Soyeht`) | P0 | Yes |
| ST-Q-SCCS-011 | Run `ClawAPITests` (iOS) | Passes. `SoyehtCore.SoyehtAPIClient.APIErrorBody` resolves unambiguously | P0 | Yes |
| ST-Q-SCCS-012 | Run `SoyehtMacTests` SwiftPM target | Passes (currently 181/181 including 10 AgentType migration). No link error from shared Claw code | P0 | Yes |

### Notification round-trip

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCCS-013 | `ClawStoreViewModel` polling reaches a terminal install transition | Posts `ClawStoreNotifications.installedSetChanged`. Test receives it via `NotificationCenter.default.publisher` | P1 | Yes |
| ST-Q-SCCS-014 | `ClawDetailViewModel` polling reaches a terminal transition | Same behaviour. Exactly ONE notification per transition (not one per polling tick) | P1 | Yes |
| ST-Q-SCCS-015 | Uninstall path reaches terminal `.notInstalled` | Notification also posted. Subscribers refresh their caches | P1 | Yes |
| ST-Q-SCCS-016 | `installFailed` terminal state | Notification posted so listeners can clear "installing" affordances | P2 | Yes |

## Regression checks (diff-time tripwires)

These are not step-by-step tests, but should be asserted in CI or a pre-merge script:

1. `rg --pcre2 '^\s*public\s+init' Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawModels.swift` should return a public init for every exposed `struct`.
2. `rg -l 'import UIKit|import ActivityKit' Packages/SoyehtCore/` should return empty.
3. `find TerminalApp/Soyeht/ClawStore -name 'ClawModels.swift' -o -name 'ClawStoreViewModel.swift'` should return empty — the iOS copies must stay deleted.
4. The iOS target's pbxproj must not reference `ClawModels.swift` under `TerminalApp/Soyeht/ClawStore/` — any re-addition is a P0 regression.

## Out of Scope
- SwiftUI views (`MacClawStoreRootView`, `MacClawDetailView`, iOS `ClawStoreView`, etc.) — these are intentionally still platform-specific (iOS uses `.presentationDetents`, macOS uses AppKit window chrome). They import `SoyehtCore` but are not tested here.
- Live backend behavior — covered under `claw-store-deploy.md` (iOS) and `mac-claw-store-window.md` (macOS).

## Related code
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawModels.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawRoute.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawMockData.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawStoreViewModel.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDetailViewModel.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawSetupViewModel.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDeployActivity.swift` — protocol + NoOp
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDeployMonitor.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawNotificationHelper.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient+Claws.swift`
- `TerminalApp/Soyeht/ClawStore/ClawDeployActivityManager.swift` — iOS-only, conforms to `ClawDeployActivityManaging`
- `TerminalApp/Soyeht/SoyehtAPIClient.swift` — now `import SoyehtCore` at top
