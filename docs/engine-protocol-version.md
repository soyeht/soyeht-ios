# Engine protocol version — pre-flight handshake

> If you are adding a `BootstrapStatusClient` consumer or an iOS client
> that calls a new theyos engine endpoint, **read this file first**.
> The companion test contract lives in
> `Packages/SoyehtCore/Tests/SoyehtCoreTests/EngineCompatTests.swift`.

## What this prevents

iOS and theyos live in separate repos and ship on separate cadences.
Before this gate existed, a Soyeht.app build calling a freshly-added
engine endpoint would talk to an older engine on the user's Mac and
see an opaque "unexpected response type" / 404 / decode failure deep
in the flow — typically during pairing or Claw Store install.

`EngineCompat` is the pre-flight that converts that opaque error into
a clear "update Soyeht on this Mac" message **before** any mutating
POST is attempted.

## Two related-but-different fields on `/bootstrap/status`

```swift
public let version: UInt64        // envelope CBOR version — always 1 today
public let engineVersion: String  // semver of the engine binary — e.g. "0.1.17"
```

Comparison happens on `engineVersion` (the semver string). The envelope
`version: UInt64` is a wire-format generation counter for the CBOR
envelope itself — different concept, different evolution.

**Easy mistake**: comparing `version` thinking it is the engine semver.
It would always succeed because the envelope has never been bumped past
`1`. Tests in `EngineCompatTests` lock the correct field.

## How the gate runs

```swift
public static func assertCompatible(via statusClient: BootstrapStatusClient) async throws {
    let status = try await statusClient.fetch()
    guard isCompatible(status.engineVersion) else {
        throw BootstrapError.engineTooOld(
            found: status.engineVersion,
            required: minSupportedEngineVersion
        )
    }
}
```

Every mutating bootstrap client (`BootstrapInitializeClient.initialize`,
`BootstrapAcceptHouseholdClient.accept`) routes through this gate
before its main POST. If the engine is too old, the user sees the
typed `BootstrapError.engineTooOld` and a localized message like:

> This Mac is running an older Soyeht engine (0.1.12). Update Soyeht
> on it to 0.1.17 or newer first.

Unparseable engine versions (`"unknown"`, `""`, missing dots) are
treated as incompatible on purpose — we cannot prove they implement
the endpoints we depend on, so we refuse them rather than guess.

If `/bootstrap/status` itself fails (network drop, decode error),
that error propagates unchanged — the precheck never masks the
original failure with a misleading version error.

## When to bump `minSupportedEngineVersion`

Increment `EngineCompat.minSupportedEngineVersion` whenever the iOS
client begins calling an endpoint or expecting a wire field that the
previous engine version did not have. Three things land in the same
commit:

1. The matching theyos release tag must already be on GitHub
   (`soyeht/theyos` releases) — otherwise users updating Soyeht.app
   are refused against any non-updated Mac.
2. `EngineCompat.minSupportedEngineVersion` bumps to that release's
   semver.
3. `scripts/theyos-engine.version` bumps to the same semver so the
   next SoyehtMac DMG ships with the matching engine baked in.

`scripts/theyos-engine.sha256` gets the SHA-256 of the new release
tarball added so `scripts/fetch-engine.sh` can verify integrity at
build time.

The companion doc [engine-version.md](engine-version.md) explains the
engine-pin side of this in more detail (when a bump is the right fix
vs masking a real bug).

## Semver comparison rules

`EngineCompat.compareSemver` and `parseSemver` understand the
`MAJOR.MINOR.PATCH` core of a semver string:

- Pre-release / build metadata is stripped before comparison —
  `"0.1.17-rc.1"` compares equal to `"0.1.17"`.
- Each numeric component is parsed as `UInt64`.
- Any non-numeric component, missing component, or extra component
  yields `nil` from `parseSemver` and `.orderedAscending` from
  `compareSemver` (callers refuse the engine).
- `v0.1.17` (with `v` prefix) is **not** accepted — the format uses
  bare semver, the `v` prefix is only on the git tag.

## Testing the gate

`EngineCompatTests` covers:

- `parseSemver` — canonical form, pre-release/build metadata stripping,
  rejection of malformed shapes.
- `compareSemver` — per-component ordering, unparseable-side semantics.
- `isCompatible` — accepts equal + newer, rejects older + unparseable.
- `assertCompatible` — passes on supported engine, throws
  `BootstrapError.engineTooOld` with the right `found`/`required`
  payload on ancient + unparseable engines.
- `BootstrapError.engineTooOld` localized description mentions both
  the found and required versions verbatim.

Fixtures use `EngineCompat.minSupportedEngineVersion` referenced
dynamically (so the suite auto-tracks bumps) plus fixed `"0.0.1"` /
`"v0.1.17"` / `"unknown"` strings that stay invalid regardless of
the floor.

## Files

| File                                                                                | Role                                |
| ----------------------------------------------------------------------------------- | ----------------------------------- |
| `Packages/SoyehtCore/Sources/SoyehtCore/EngineVersion/EngineVersion.swift`          | `EngineCompat` semver gate          |
| `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapState.swift`             | `BootstrapError.engineTooOld` case  |
| `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapInitializeClient.swift`  | Calls `assertCompatible` pre-flight |
| `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapAcceptHouseholdClient.swift` | Calls `assertCompatible` pre-flight |
| `Packages/SoyehtCore/Tests/SoyehtCoreTests/EngineCompatTests.swift`                 | Contract tests                      |

## See also

- [engine-version.md](engine-version.md) — when bumping the pinned
  engine version is the right fix and how to do it safely.
- [server-model.md](server-model.md) — `Server` entity and registry
  that surface paired hosts to the UI.
