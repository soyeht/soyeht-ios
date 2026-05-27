# Identity facade — `SoyehtIdentity`

> Companion to [server-model.md](server-model.md). The two facades are the iOS app's only UI-facing source of truth for the user's Soyeht.

## The rule

UI consumes `SoyehtIdentity.shared`. `HouseholdSessionStore` and `ActiveHouseholdState` are **protocol/storage layer** — only `Household/*` orchestrators (`HouseholdMachineJoinRuntime`, `HouseholdPoPSigner`, `HouseholdDevicePairingService`, etc.) touch them directly.

```swift
// CORRECT — UI
@ObservedObject private var identity = SoyehtIdentity.shared

if identity.isActive { ... }
if let snapshot = identity.active {
    Text(snapshot.displayName)
}
identity.thisDevice.localPairingDeviceId   // for setup invitations

// WRONG — UI
let store = HouseholdSessionStore()
if let s = try? store.load() { ... }       // collapses 3 states into 1
```

## Why a state enum, not a Bool

`SoyehtIdentity.state` is quad-valued, not optional:

| State | Meaning | UI response |
| --- | --- | --- |
| `.unknown` | Pre-resolve | Wait or call `reload()` |
| `.inactive` | No local identity (confirmed) | Route to onboarding |
| `.active(snapshot)` | A valid identity is loaded | Show the app |
| `.unavailable(.protectedDataUnavailable)` | iPhone locked / Keychain unreadable | Auto-recovers via `protectedDataDidBecomeAvailable` — keep waiting |
| `.unavailable(.decodingFailed)` | Keychain entry exists but malformed | Log loudly; falls through to onboarding only if no other state exists |

`isActive` is a convenience that returns `true` only for `.active`. The collapsed `try? store.load() != nil` pattern silently treated locked Keychain and corrupted entries as "no household" — that bug is fixed by the state enum and must not be reintroduced.

## What lives where

```
View / ViewModel ─── SoyehtIdentity (this file)
                         │
                         ▼
                   HouseholdSessionController (internal adapter, intacto)
                         │
                         ▼
                   HouseholdSessionStore (Keychain adapter, intacto)
                         │
                         ▼
                   Keychain "household.active.session"

Household/* orchestrators continue to receive ActiveHouseholdState
directly — they live BELOW the facade. To bridge between layers when
a view needs to feed an orchestrator, use snapshot.underlying.
```

## Out-of-band saves

Anyone writing to `HouseholdSessionStore` (e.g. `HouseholdPairingService.pair` finishing a fresh pair) must call `SoyehtIdentity.shared.reload()` immediately after — the facade is read-from-Keychain on demand and does not subscribe to writes. Today this happens at:

- `SSHLoginView.handlePairing(...)` and `SSHLoginView.handleDevicePairing(...)`
- `HouseholdPairingViewModel.pairNow(...)`

If you add a new save site, add the `reload()` call too.

## Files

| File | Role |
| --- | --- |
| `TerminalApp/Soyeht/Identity/SoyehtIdentity.swift` | Singleton + state machine + observers |
| `TerminalApp/Soyeht/Identity/SoyehtIdentityState.swift` | `state` enum + `UnavailableReason` |
| `TerminalApp/Soyeht/Identity/SoyehtIdentitySnapshot.swift` | UI-facing wrapper over `ActiveHouseholdState` |
| `TerminalApp/Soyeht/Identity/OwnerDevice.swift` | This iPhone/iPad as an owner device |
| `TerminalApp/Soyeht/Identity/SoyehtIdentity+Environment.swift` | SwiftUI environment key |
| `TerminalApp/SoyehtTests/SoyehtIdentityTests.swift` | State machine + snapshot + OwnerDevice contract |

## See also

- [server-model.md](server-model.md) — companion facade for paired Macs/Linux hosts (`ServerRegistry`).
- [iphone-loss-recovery-plan.md](iphone-loss-recovery-plan.md) — recovery flow that will extend `OwnerDevice` with DeviceCert (`d_id`); `localPairingDeviceId` was named explicitly to leave that namespace free.
