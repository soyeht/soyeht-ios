# iOS architecture — the four UI-facing facades

> Top-level summary of the boundaries the iOS app converged on after
> PR-1 (`SoyehtIdentity`), PR-2 (`ServerRegistry`), PR-3
> (`ClawInstallTarget`), and PR-5A (`GuestImageReadiness`). Use this as
> the entry point; the per-facade docs go deeper.
>
> **This document and the matching `LegacyBoundaryUsageTests` are
> guardrail and documentation, not destructive cleanup.** The legacy
> stores (`HouseholdSessionStore`, `ActiveHouseholdState`,
> `PairedMacsStore`, `SessionStore`) remain the physical
> storage/protocol boundaries until a later migration window. Nothing
> was deleted in the PR that introduced this file; the goal is only to
> prevent the architecture from regressing while the remaining UI sites
> migrate piecewise.

## The rule, in one sentence

iOS UI talks to the **four facades**. Everything else
(`HouseholdSessionStore`, `ActiveHouseholdState`, `PairedMacsStore`,
`SessionStore`, `ClawAPITarget.household`, the `.householdStore` /
`.householdDetail` route cases) is protocol / storage / wire vocabulary
and is intentionally hidden behind those facades.

## The four facades

| Facade | Owns | UI question it answers |
| --- | --- | --- |
| `SoyehtIdentity.shared` | The user's identity + owner device | "Is there an active Soyeht? Who is this device?" |
| `ServerRegistry.shared` | The list of paired Macs and Linux admin hosts | "How many servers? Which Mac is this? Rename / remove this server." |
| `ClawInstallTarget(serverID:)` | The thing a Claw is installed on | "Open the Claw Store for this server." |
| `GuestImageReadiness` | Whether a Mac can host Claws right now | "Is install allowed for this target?" |

The links to deeper docs:

- [identity-facade.md](identity-facade.md) — `SoyehtIdentity`
- [server-model.md](server-model.md) — `Server` + `ServerRegistry`
- [claw-install-target.md](claw-install-target.md) — `ClawInstallTarget` + resolver
- WWDC-style overview of `GuestImageReadiness` is inside the
  `ClawStore/GuestImageReadinessGate.swift` doc-header until it earns
  its own file.

## Household is protocol / storage vocabulary, not UI vocabulary

The word *household* survives in three places on purpose:

1. **Wire**: the `/household/*` HTTP routes and the `ClawAPITarget.household`
   PoP-signed install path. These are the engine's protocol surface
   and don't change in this cleanup.
2. **Storage**: `HouseholdSessionStore` (keychain), `ActiveHouseholdState`
   (the decoded shape), and the internal `HouseholdSessionController`
   adapter that bridges keychain ↔ observable state.
3. **`Household/*` orchestrators**: `HouseholdMachineJoinRuntime`,
   `HouseholdPairingViewModel`, `APNSRegistrationCoordinator`, etc.
   These sit *below* the facade and are allowed to consume
   `ActiveHouseholdState` directly.

What does **not** happen any more:

- New iOS UI does not construct `.householdStore` / `.householdDetail`
  route cases. Those cases stay alive in `ClawRoute` for macOS; iOS
  switches over them with `EmptyView()` placeholders so saved
  navigation state doesn't crash.
- New iOS UI does not construct household Claw wire targets directly.
  The single exception is `ClawInstallTargetResolver.swift`, which maps
  a `Server.ID` to either a legacy `ServerContext` or the selected Mac's
  PoP household endpoint.
- New iOS UI does not read `SessionStore.shared.pairedServers` or
  `PairedMacsStore.shared.macs` to list or count servers. Both go
  through `ServerRegistry.shared`.

These rules are enforced by source-slice tests in `SoyehtTests/`:

- `ClawRouteUsageTests` — `.householdStore` / `.householdDetail` and
  `ClawAPITarget.household` boundary.
- `LegacyBoundaryUsageTests` — `SessionStore.pairedServers`,
  `PairedMacsStore.shared.macs`, `HouseholdSessionStore()`
  construction, `ClawStoreView(target:)` legacy initializer, and
  hidden `?? .household` fallbacks in iOS UI.

## Recent cleanup: `SSHLoginView`

`SSHLoginView.swift` used to be the last UI-layer exemption for direct
identity/server storage reads. It now follows the same facade rules as
the rest of the app:

- identity routing reads `SoyehtIdentity.shared` instead of constructing
  `HouseholdSessionStore()`;
- server routing reads `ServerRegistry.shared.servers` and resolves
  token-backed `ServerContext`s through `SessionStore.context(for:)`
  instead of reading `SessionStore.pairedServers` to count/list
  servers;
- `SessionStore` remains in the file only for the responsibilities it
  still owns physically: active server id, server context/token lookup,
  pending deep links, cached instances, and navigation state;
- `AppState.householdHome` / `pairingSuccess` / `recoveryMessage` carry
  `SoyehtIdentitySnapshot`, not `ActiveHouseholdState`. The file only
  touches `snapshot.underlying` at the boundary where legacy
  `Household/*` views/orchestrators still require the protocol-level
  value.

## Recent cleanup: Claw household routing

`ClawStore/ClawStoreView.swift` and `ClawStore/ClawDetailView.swift`
used to construct their ViewModels with a hidden
`resolution.apiTarget ?? .household` fallback. That made the
`.unavailable` UI path safe in practice, but it still smuggled the
household wire target into iOS UI code.

The views are now split into two layers:

- the public wrapper resolves `ClawInstallTarget` and renders
  `MacClawUnavailableView` before any Claw ViewModel is constructed
  when the resolver returns `.unavailable`;
- the private resolved view (`ResolvedClawStoreView` /
  `ResolvedClawDetailView`) requires `resolution.apiTarget` and treats
  a missing API target as a programmer error.

The only iOS production code that can still produce a household Claw
wire target is `ClawInstallTargetResolver.swift`. For Macs paired via
the household flow, it now resolves a selected-Mac
`ClawAPITarget.householdEndpoint(URL)` rather than the aggregate
`.household` target, so multi-Mac Claw Store routing stays explicit.
The source-slice tests still forbid `?? .household` anywhere in iOS UI
so that an implicit aggregate fallback cannot reappear quietly.

## Where the migration is *not yet* finished

There are no known UI-layer facade violations left in this document.
The legacy storage types remain alive behind the facades until a later
storage migration window.

## See also

- [identity-facade.md](identity-facade.md)
- [server-model.md](server-model.md)
- [claw-install-target.md](claw-install-target.md)
- [post-merge-recovery-plan.md](post-merge-recovery-plan.md) — the
  broader context for why these facades landed in this order.
