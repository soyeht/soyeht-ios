---
id: soyeht-core-session-parity
ids: ST-Q-SCSP-001..014
profile: quick
automation: auto
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: shared
---

# SoyehtCore Session Layer Parity (Fase 0)

## Objective
Pin the Fase 0 unification delivered on `feat/claw-store-macos`: every `SessionStore` method that iOS code depended on (and that the Claw ViewModels transitively call) now exists as a `public` member on the SoyehtCore `SessionStore`, and `ServerContext` lives in SoyehtCore as a shared type. The iOS app keeps the names it used to have via a `typealias` to SoyehtCore, so `@testable import Soyeht` still resolves `ServerContext` and `PairedServer`. `SoyehtAPIClient` inside SoyehtCore gained a `context:`-scoped overload of `authenticatedRequest(...)` so every Claw Store endpoint can pin requests to a specific paired server instead of the singleton `activeServer`.

## Risk
- `SessionStore.context(for:)` is missing from SoyehtCore → `ClawSetupViewModel` at SoyehtCore level fails to compile because its `init` references `store.context(for:)`.
- `SessionStore.currentContext()` convenience never returns a context even when a server is paired → `InstalledClawsProvider.refresh()` early-returns forever, UI looks empty.
- `ServerContext` exists in both iOS and SoyehtCore as separate types → the iOS Claw sheet constructs an iOS-local `ServerContext` and hands it to a SoyehtCore ViewModel; Swift accepts this silently only when names collide, causing subtle runtime mismatches. Typealias collapse is mandatory.
- `authenticatedRequest(path:method:queryItems:context:)` uses `context.token` for the Bearer header instead of the active-server token → multi-server fan-out is broken, Claw endpoints get the wrong server's credentials.
- iOS `SessionStore.tokenForServer(id:)` is keychain-backed; SoyehtCore's copy forgets to hit the keychain → fresh macOS app launches can't retrieve the token after a restart.
- iOS `SoyehtAPIClient` still has a private `ServerContext` helper that shadows SoyehtCore's → ambiguous reference breaks compilation.
- `@testable import Soyeht` in existing iOS tests suddenly fails because `ServerContext` is no longer declared in Soyeht — typealias must be `typealias` not `struct` to preserve `@testable` access.

## Preconditions
- `feat/claw-store-macos` checked out, both Xcode projects and SoyehtCore SPM package resolvable
- Ability to run iOS and macOS build matrices

## How to automate
- **Build matrix**:
  ```
  cd Packages/SoyehtCore && swift build
  xcodebuild -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
  xcodebuild -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac \
    -destination 'platform=macOS' build
  ```
- **Contract grep**:
  - `rg 'public func context\(for' Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift` → 1 hit
  - `rg 'public func currentContext' Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift` → 1 hit
  - `rg 'public struct ServerContext' Packages/SoyehtCore/Sources/SoyehtCore/Store/ServerContext.swift` → 1 hit
  - `rg '^typealias ServerContext' TerminalApp/Soyeht/SessionStore.swift` → 1 hit
  - `rg 'authenticatedRequest\([^)]*context:' Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient.swift` → 1+ hits
- **Behavior** (unit test — new): construct two `PairedServer` values, add tokens, call `SessionStore.context(for: a.id)` and assert the returned context's Bearer header matches the keychain-stored token for `a`, NOT `b`.

## Test Cases

### Shape / API surface

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCSP-001 | `ServerContext` is defined in `Packages/SoyehtCore/Sources/SoyehtCore/Store/ServerContext.swift` as `public struct`, `Sendable`, `Equatable`, with `public init(server:token:)` and computed `host`/`serverId` | Matches implementation | P0 | Yes |
| ST-Q-SCSP-002 | iOS `SessionStore.swift` declares `typealias ServerContext = SoyehtCore.ServerContext` and `typealias PairedServer = SoyehtCore.PairedServer` | Exists. No local `struct ServerContext` remains in iOS | P0 | Yes |
| ST-Q-SCSP-003 | `SoyehtCore.SessionStore.context(for serverId: String) -> ServerContext?` is public | Resolves via `pairedServers.first(where:)` + `tokenForServer(id:)`. Returns nil only if server not paired or token missing | P0 | Yes |
| ST-Q-SCSP-004 | `SoyehtCore.SessionStore.currentContext() -> ServerContext?` is public | Returns `context(for: activeServer.id)` when there IS an active server, else nil | P0 | Yes |
| ST-Q-SCSP-005 | `SoyehtCore.SessionStore.tokenForServer(id:)` is keychain-backed on macOS AND iOS | Keychain service identifier matches iOS's (`com.soyeht.mobile`) so existing entries are reachable. Cross-app isolation preserved (not synchronizable) | P1 | Yes |

### API client overload

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCSP-006 | `SoyehtAPIClient.authenticatedRequest(path:method:queryItems:context:)` overload exists and is public | Yes, mirrors the single-active-server variant but uses the passed context's token + host | P0 | Yes |
| ST-Q-SCSP-007 | All `SoyehtAPIClient+Claws` methods accept `context: ServerContext` as the trailing parameter | Every Claw endpoint takes explicit context. No implicit use of `store.activeServer` in any Claw method | P0 | Yes |
| ST-Q-SCSP-008 | Calling `getClaws(context: contextA)` while `activeServer == B` | Hits server A (A's host + A's token). The `Authorization: Bearer` header is A's token, verified via URLProtocol stub | P0 | Yes |

### Build & link matrix

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCSP-009 | `swift build` inside `Packages/SoyehtCore` | Succeeds | P0 | Yes |
| ST-Q-SCSP-010 | `xcodebuild build` iOS | Succeeds. `@testable import Soyeht` in tests still resolves `ServerContext`/`PairedServer` via typealias | P0 | Yes |
| ST-Q-SCSP-011 | `xcodebuild build` macOS | Succeeds. No duplicate `ServerContext` symbol | P0 | Yes |

### Runtime behavior

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SCSP-012 | Pair two servers (A, B). Call `SessionStore.context(for: A.id)`. Assert tuple `(host, token)` | host == A.host; token == keychain entry for A. Does NOT return B's token under any reordering | P0 | Yes |
| ST-Q-SCSP-013 | Remove server A via `SessionStore.removeServer(id: A.id)` | `context(for: A.id)` subsequently returns nil. Keychain entry for A is deleted. Server B is untouched | P1 | Yes |
| ST-Q-SCSP-014 | `SessionStore.loadInstances() / saveInstances(_:)` round-trip | Writes to disk under the active server's scope and reloads identically on fresh app launch | P1 | Yes |

## Invariants

1. **Single `ServerContext` type.** There must be exactly one `ServerContext` definition in the entire repo; everywhere else it's `typealias` or `import SoyehtCore`.
2. **No `activeServer` dependency inside Claw endpoints.** Every method in `SoyehtAPIClient+Claws.swift` takes `context: ServerContext` explicitly. Grep `rg 'activeServer' Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient\+Claws.swift` must be empty.
3. **Keychain service identifier stable.** Changing it from `com.soyeht.mobile` is a P0 — existing users lose their sessions.
4. **Typealias, not re-declaration.** iOS `SessionStore.swift` uses `typealias`. Re-declaring the struct would allow two incompatible types to coexist — rejected.

## Out of Scope
- Removing the legacy iOS-only `TerminalApp/Soyeht/SoyehtAPIClient.swift` (still exists, uses `ServerContext` via typealias; removal is a later cleanup).
- Rewriting iOS screens to use the SoyehtCore `SessionStore` directly (iOS code keeps its `SessionStore.shared`; SoyehtCore has its own `SessionStore.shared` that macOS code uses).

## Related code
- `Packages/SoyehtCore/Sources/SoyehtCore/Store/ServerContext.swift`
- `Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift` — gained `context(for:)`, `currentContext()`, keychain parity
- `Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient.swift` — gained `authenticatedRequest(...context:)` overload
- `Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient+Claws.swift` — every endpoint takes `context: ServerContext`
- `TerminalApp/Soyeht/SessionStore.swift` — typealiases `ServerContext` and `PairedServer` to SoyehtCore
- `TerminalApp/Soyeht/SoyehtAPIClient.swift` — `import SoyehtCore` at top, kept for iOS-local endpoints
- `TerminalApp/Soyeht/SoyehtAPIClient+Instance.swift` — preserves `instanceAction` for InstanceListView after Claws moved out
