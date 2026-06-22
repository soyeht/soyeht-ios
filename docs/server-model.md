# Server model — unified entity for Macs and Linux hosts

> If you are adding code that pairs, lists, mutates, or polls a paired
> Mac or Linux host, **read this file first**. The companion test
> contracts live in
> `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerInventoryWriterTests.swift`
> (the single-writer boundary, read-side guard, and v1↔writer parity — the
> suite that actually exercises the writer) and
> `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerStoreMigrationTests.swift`
> (decoder + legacy migration contract).

## What this replaces

Historically the iOS app tracked paired hosts in **two parallel
stores**:

| Legacy store                              | Stored what                       | Storage          |
| ----------------------------------------- | --------------------------------- | ---------------- |
| `PairedMacsStore` (iOS-only)              | Macs paired via QR-then-Bonjour   | UserDefaults + Keychain |
| `SessionStore.pairedServers` (iOS+macOS)  | Engines (`.engine`) + Linux admin hosts (`.adminHost`) | UserDefaults |

Same Mac could appear in both lists. UI code had to dedupe by hostname,
which it usually got wrong. The home footer's "X servers connected"
badge silently read from `pairedServers` and showed `0` for every user
whose only Mac came in via the iPhone-first QR flow.

`Server`, `ServerStore`, `ServerInventoryWriter`, and `ServerRegistry`
are the unified replacement. The live persisted authority is still the
v1 `ServerStore`; `ServerInventoryWriter` is the additive facade used by
approved adapters while the v2 model remains shadow/test-only.

## The three rules

### Rule 1 — Always render `server.displayName`

```swift
// CORRECT
Text(server.displayName)

// WRONG
Text(server.hostname)         // hostname only — ignores user's alias
Text(server.alias ?? "")      // raw alias — misses fallback to hostname
```

`Server.displayName` returns the typed alias when set (and non-whitespace),
falling back to the engine-reported hostname while the user has not
chosen an alias yet. Mirrors `PairedMac.displayName` semantics so the
transition from the legacy types is a no-op at the call site.

### Rule 2 — Always mutate through `ServerRegistry`

```swift
// CORRECT
let result = ServerRegistry.shared.rename(serverID: id, to: input)
switch result {
case .success: ...
case .duplicate(let conflictingMacID): show duplicate-name error
case .invalid(let reason): show validation error
case .unknownMac: dismiss
}

// WRONG — never mutate the persisted store directly
var s = ServerStore().load().first!
s.alias = "..."               // bypasses validation, dedup, persistence
ServerStore().upsert(s)
```

`ServerRegistry` is the single funnel that:

1. Validates with `MacAliasValidator` (trim + non-empty + length ≤
   `MacAliasRules.maxLength` + no forbidden characters);
2. Rejects duplicates with a case-insensitive comparison across **all**
   other servers in the registry (not just same-kind);
3. Dispatches to the legacy store only for compatibility side effects
   (Mac pairing secret cleanup, token rows, navigation/cache cleanup);
4. Atomically updates `@Published servers` and persisted `ServerStore`
   through `ServerInventoryWriter` v1 parity methods — SwiftUI sinks
   never see an inconsistent moment.

Mac local-pairing flows use `ServerRegistry.upsertMacPairing(...)` for
the same reason: `PairedMacsStore` still owns the Keychain pairing
secret, but the paired-server list is written through the registry
funnel and mirrored into `ServerStore` synchronously through the writer.

### Rule 3 — Kind-aware affordances live on `Server.kind`

```swift
let macs   = ServerRegistry.shared.macs        // kind == .mac
let linux  = registry.servers.filter { $0.kind == .linux }
```

The home `// apps` section shows only Macs. The home footer "X servers
connected" badge counts everything in the registry that has a recent
theyOS poll heartbeat. Both kinds get the same alias UX through
`ServerRegistry.rename`.

## Migration and legacy adapters

Triggered once per install at app launch:

```swift
let legacyMacSeed    = PairedMacsStore.shared.macs.map { $0.toServer() }
let legacyServerSeed = SessionStore.shared.pairedServers.map { $0.toServer() }
ServerRegistry.shared.migrateLegacy(seed: legacyMacSeed + legacyServerSeed)
```

The iOS app imports both `PairedMacsStore` and
`SessionStore.pairedServers` through `ServerRegistry`, which delegates
v1 persistence to `ServerInventoryWriter`. The macOS app has no
`PairedMacsStore` seed, so it imports the `SessionStore.pairedServers`
seed through the writer before it decides whether to show Welcome or
restore main windows:

```swift
ServerInventoryWriter().migrateLegacyIfNeeded(
    seed: SessionStore.shared.pairedServers.map { $0.toServer() }
)
```

Idempotent. A sentinel inside `ServerStore` makes subsequent calls
no-ops. The legacy stores stay intact — no destructive cleanup runs in
this release so a rollback to the previous build does not lose pairings.

After startup, `ServerRegistry.installLegacyMirror()` keeps the v1 store
aligned with legacy-originated mutations while the migration is still in
progress:

- `PairedMacsStore` changes refresh the registry synchronously on the
  main actor.
- `SessionStore.pairedServers` mutations write their projected
  `Server` row through `ServerInventoryWriter` synchronously, then fire
  the registry mirror callback for in-memory observers.
- The writer's v1 reconcile path treats the legacy seed as membership
  input, but preserves canonical enrichment already written through the
  registry (`theyOS`, explicit endpoints, and newer `lastSeenAt` data)
  for rows that still exist in the legacy seed.

`PairedServer.toServer()` accepts both legacy raw `kind` values
(`"engine"` → `.mac`, `"adminHost"` → `.linux`) so a user who has not
re-paired since the previous schema still migrates cleanly. Decoder
backward-compat is locked by `ServerStoreMigrationTests.test_kindDecoder_acceptsLegacyPairedServerRawValues`.

## Transition state

`ServerRegistry` is the UI-facing list and mutation authority. The
legacy stores remain alive as adapters while the storage migration
continues:

- `PairedMacsStore` still owns device identity, per-Mac pairing
  secrets, and the `PairedMac` bridge required by presence clients.
- `SessionStore` still owns server credentials, active server id,
  cached instance state, navigation state, and `ServerContext` lookup;
  its canonical inventory projections delegate to `ServerInventoryWriter`.
- `ServerStore` is the persisted unified list. `ServerInventoryWriter`
  wraps it for the approved v1 parity paths in `ServerRegistry`,
  `SessionStore`, and macOS startup migration. The v2 envelope, shadow
  comparer, and rollback projection helpers remain test/shadow-only and
  are not a live authority.

The remaining sweep is tracked separately. For now, follow these rules:

- **New code** that needs to enumerate paired Macs or Linux hosts
  should consume `ServerRegistry.shared.servers` (or `.macs`).
- **New code** that renames, removes, or records a paired Mac should go
  through `ServerRegistry`. Do not add new direct
  `PairedMacsStore.upsertMac`, `PairedMacsStore.remove`,
  `SessionStore.renameServer`, or `SessionStore.removeServer` call sites
  outside the compatibility adapters.
- Existing protocol-level code may still use `PairedMacsStore` or
  `SessionStore` for credentials/context, but listing and user-visible
  mutation should be added at the registry layer first.

## Known follow-ups (single-owner hardening)

Invariants that are guarded today but not yet fully closed:

- **Read side.** `ServerInventoryWriterTests.test_adHocServerStoreLoadReadsAreConfinedToAllowlist`
  forbids new `ServerStore().load()` reads. The one allow-listed site —
  `ClawDetailViewModel`'s injected `pairedServerCountProvider` default — still
  reads raw UserDefaults; iOS UI construction sites (`ClawDetailView`,
  `MacClawDetailView`) should inject a `ServerRegistry.shared.servers.count`
  provider so the count comes from the in-memory authority, not a throwaway store.
- **Shadow comparer.** `ServerStoreShadowComparer` reports canonical↔legacy
  divergence as category counts (`ServerStoreShadowComparerTests`), but it is
  still a diagnostic — not yet a live blocking invariant on the writer's
  reconcile output.
- **Parallel owners.** `PairedMacsStore` and `SessionStore.pairedServers` remain
  the membership / credential origin-of-record; the persisted v1 `ServerStore` is
  a reconciled projection of them. Collapsing them into a single owner is the
  remaining sweep — do not add new write paths to the legacy stores meanwhile
  (see the Transition state rules above).

## Files

| File                                                                  | Role                            |
| --------------------------------------------------------------------- | ------------------------------- |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/Server.swift`          | `Server`, `ServerKind`, `TheyOSSnapshot` |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStore.swift`     | Persistence + migration sentinel |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift` | V1 persistence facade + shadow/v2 helper boundary |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/PairedServer+Server.swift` | Legacy → unified adapter (engines + admin hosts) |
| `Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift`     | Credentials/context adapter + writer-backed inventory projection |
| `TerminalApp/Soyeht/Pairing/PairedMac+Server.swift`                   | Legacy → unified adapter (Macs) |
| `TerminalApp/Soyeht/Server/ServerRegistry.swift`                      | Observable single mutator funnel, backed by writer v1 parity methods |
| `TerminalApp/Soyeht/AppDelegate.swift`                                | iOS startup migration call |
| `TerminalApp/SoyehtMac/AppDelegate.swift`                             | macOS startup migration call through writer |
| `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerStoreMigrationTests.swift` | Decoder + migration contract |
| `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerInventoryWriterTests.swift` | Single-writer + read-side boundary guards, v1↔writer parity |
| `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerStoreShadowComparerTests.swift` | Canonical↔legacy projection divergence diagnostic |

## See also

- [mac-display-name.md](mac-display-name.md) — current legacy-store
  rules for the `PairedMacsStore` adapter. `ServerRegistry` remains
  the UI-facing mutation funnel.
- [engine-version.md](engine-version.md) — how the bundled theyos
  engine binary version is pinned. Engines must be compatible with
  the iOS client (`EngineCompat.minSupportedEngineVersion`).
- [engine-protocol-version.md](engine-protocol-version.md) — the
  wire-version handshake that pre-flight checks compatibility.
