# Server model — unified entity for Macs and Linux hosts

> If you are adding code that pairs, lists, mutates, or polls a paired
> Mac or Linux host, **read this file first**. The companion test
> contract lives in `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerStoreMigrationTests.swift`.

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

`Server` and `ServerRegistry` are the unified replacement.

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
let result = ServerRegistry.shared.setAlias(serverID: id, alias: input)
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
3. Updates `lastSeenAt` so the entry sorts to the top after an edit;
4. Atomically updates `@Published servers` and persisted `ServerStore`
   together — SwiftUI sinks never see an inconsistent moment.

### Rule 3 — Kind-aware affordances live on `Server.kind`

```swift
let macs   = ServerRegistry.shared.macs        // kind == .mac
let linux  = registry.servers.filter { $0.kind == .linux }
```

The home `// apps` section shows only Macs. The home footer "X servers
connected" badge counts everything in the registry that has a recent
theyOS poll heartbeat. Both kinds get the same alias UX through
`setAlias`.

## Migration from the legacy stores

Triggered once per install in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`:

```swift
let legacyMacSeed    = PairedMacsStore.shared.macs.map { $0.toServer() }
let legacyServerSeed = SessionStore.shared.pairedServers.map { $0.toServer() }
ServerRegistry.shared.migrateLegacy(seed: legacyMacSeed + legacyServerSeed)
```

Idempotent. A sentinel inside `ServerStore` makes subsequent calls
no-ops. The legacy stores stay intact — no destructive cleanup runs in
this release so a rollback to the previous build does not lose pairings.

`PairedServer.toServer()` accepts both legacy raw `kind` values
(`"engine"` → `.mac`, `"adminHost"` → `.linux`) so a user who has not
re-paired since the previous schema still migrates cleanly. Decoder
backward-compat is locked by `ServerStoreMigrationTests.test_kindDecoder_acceptsLegacyPairedServerRawValues`.

## Transition state (as of 2026-05-26)

The legacy stores remain authoritative for everything that has not yet
been rewritten to consume `ServerRegistry`. Specifically:

- `MacHomeRow`, `MacDetailView`, `PairedMacsListView`,
  `MacPresenceClient`, `PairedMacRegistry` still take `PairedMac`.
- `ServerListView`, `InstancePickerViewController`,
  `ConnectedServersWindowController` (macOS) still read from
  `SessionStore.pairedServers`.
- `ServerRegistry.shared.servers` is populated by the migration at
  startup but no view-side mutation flows back to it yet.

The remaining sweep is tracked separately. For now, follow these rules:

- **New code** that needs to enumerate paired Macs or Linux hosts
  should consume `ServerRegistry.shared.servers` (or `.macs`).
- **Existing code** that consumes `PairedMacsStore.shared.macs` or
  `SessionStore.shared.pairedServers` is safe — those stores stay
  populated by the same mutators as before and the migration mirrors
  them into `ServerRegistry`.

## Files

| File                                                                  | Role                            |
| --------------------------------------------------------------------- | ------------------------------- |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/Server.swift`          | `Server`, `ServerKind`, `TheyOSSnapshot` |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStore.swift`     | Persistence + migration sentinel |
| `Packages/SoyehtCore/Sources/SoyehtCore/Server/PairedServer+Server.swift` | Legacy → unified adapter (engines + admin hosts) |
| `TerminalApp/Soyeht/Pairing/PairedMac+Server.swift`                   | Legacy → unified adapter (Macs) |
| `TerminalApp/Soyeht/Server/ServerRegistry.swift`                      | Observable single mutator funnel |
| `TerminalApp/Soyeht/AppDelegate.swift`                                | Startup migration call |
| `Packages/SoyehtCore/Tests/SoyehtCoreTests/ServerStoreMigrationTests.swift` | Decoder + migration contract |

## See also

- [mac-display-name.md](mac-display-name.md) — current legacy-store
  rules. Still authoritative for code that has not yet migrated to
  `Server`.
- [engine-version.md](engine-version.md) — how the bundled theyos
  engine binary version is pinned. Engines must be compatible with
  the iOS client (`EngineCompat.minSupportedEngineVersion`).
- [engine-protocol-version.md](engine-protocol-version.md) — the
  wire-version handshake that pre-flight checks compatibility.
