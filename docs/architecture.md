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
- New iOS UI does not call `ClawAPITarget.household` directly. The
  single exception is `ClawInstallTargetResolver.swift`, which holds
  the temporary single-Mac fallback.
- New iOS UI does not read `SessionStore.shared.pairedServers` or
  `PairedMacsStore.shared.macs` to list or count servers. Both go
  through `ServerRegistry.shared`.

These rules are enforced by source-slice tests in `SoyehtTests/`:

- `ClawRouteUsageTests` — `.householdStore` / `.householdDetail` and
  `ClawAPITarget.household` boundary.
- `LegacyBoundaryUsageTests` — `SessionStore.pairedServers`,
  `PairedMacsStore.shared.macs`, `HouseholdSessionStore()`
  construction, and `ClawStoreView(target:)` legacy initializer.

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

## Where the migration is *not yet* finished

The remaining known UI-layer follow-up is the Claw ViewModel fallback
below. The legacy storage types remain alive behind the facades until a
later storage migration window.

### TODO — collapse the `?? .household` fallbacks in the Claw views

`ClawStore/ClawStoreView.swift` and `ClawStore/ClawDetailView.swift`
each build their `StateObject` ViewModel with
`let target: ClawAPITarget = resolution.apiTarget ?? .household` so the
ViewModel always has a value, even for the `.unavailable` resolution
where the body renders `MacClawUnavailableView` (catalog) or never
asks the ViewModel to hit the network (detail). Both are the same
shape introduced by PR-3.

These two fallbacks are the only `.household` literals in iOS UI
outside `ClawInstallTargetResolver.swift`. They are documented in-line
and pinned by source-slice tests:

- `test_clawAPITargetHouseholdFallback_onlyInDocumentedSites` — only
  these two files may contain `?? .household`. A third site would
  re-introduce the household wire path through the back door.
- `test_documentedHouseholdFallbacks_haveExactlyOneOccurrenceEach` —
  each of the two files may hold exactly one such fallback. A
  copy-pasted helper inside the same file would be a regression too.

When `ClawStoreViewModel` / `ClawDetailViewModel` are refactored to
accept an optional target (or the `.unavailable` branch stops creating
a ViewModel at all), drop both fallbacks and remove the matching
entries from those tests' allowlists.

When those sites move over, drop the matching entry from
`LegacyBoundaryUsageTests`. The test failing with "exemption no longer
needed" is the signal to clean up the allowlist.

## See also

- [identity-facade.md](identity-facade.md)
- [server-model.md](server-model.md)
- [claw-install-target.md](claw-install-target.md)
- [post-merge-recovery-plan.md](post-merge-recovery-plan.md) — the
  broader context for why these facades landed in this order.
