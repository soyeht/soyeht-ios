# Relay Stream Guest FFI Bootstrap

The iOS Plane-1 relay stream guest uses the local Swift package at
`Native/RelayStreamGuestFFI`. Its `Package.swift` declares a local
`.binaryTarget(path: "RelayStreamGuestFFI.xcframework")`, so the XCFramework
must exist before Xcode or SwiftPM resolves the package graph.

`RelayStreamGuestFFI.xcframework` is generated and ignored. Do not commit the
binary artifact to regular git.

## Local Developer Bootstrap

Prerequisites:

- macOS with Xcode command line tools selected.
- Rust installed through `rustup`.
- Network access to fetch the pinned theyos source and Cargo dependencies.

From the repository root:

```sh
scripts/bootstrap-relay-stream-guest-ffi.sh
```

The bootstrap installs the required Rust iOS targets:

- `aarch64-apple-ios`
- `aarch64-apple-ios-sim`

It then runs `Native/RelayStreamGuestFFI/Scripts/build-relay-stream-guest-ffi-xcframework.sh`,
refreshes UniFFI Swift/C bindings, assembles the XCFramework, and writes
`RelayStreamGuestFFI.xcframework/buildinfo.json`.

The build prepares an ignored `.vendor/theyos` checkout at the immutable
revision recorded by the build script. `buildinfo.json` records that exact
revision. The pin includes the canonical `IpTunnel` resource and its reviewed
post-Open `NetworkSettings` frame, so no local source reconstruction or patch
application is required.

### Two producers, two provenance fields

An artifact is built from **two** sources, and `buildinfo.json` names both. They
answer different questions and neither substitutes for the other:

| Field | Repository | What it attests |
|---|---|---|
| `source_repo` / `source_rev` | `soyeht/theyos` | the **vendored** `household-rs` protocol source, pinned immutably by the build script |
| `ffi_source_repo` / `ffi_source_rev` | `soyeht/soyeht-ios` | the **owner** of the crate, this script and the generated bindings — resolved from the repository's `HEAD` at build time |

`ffi_source_rev` carries a `-dirty` suffix whenever the repository has any
tracked or untracked change at the moment the manifest is written, including a
dirty submodule. It is measured after the bindings are regenerated and the
framework is assembled, so a generated binding that has drifted from the commit
also marks the artifact dirty. Nothing about it is environment-overridable, and
a missing Git or a directory outside a worktree fails the build rather than
emitting unattested provenance.

**Acceptance rule for a final artifact:** `ffi_source_rev` must NOT end in
`-dirty`, and it must match the repository `HEAD` the artifact is committed
against. A `-dirty` artifact is a development build only — it attests a tree
state that no commit records, so nobody can reproduce or review what it
contains.

Use a release artifact when matching CI:

```sh
RELAY_STREAM_GUEST_FFI_PROFILE=release scripts/bootstrap-relay-stream-guest-ffi.sh
```

Run this before opening or building `TerminalApp/Soyeht.xcodeproj` from a fresh
clone. A target Run Script phase is intentionally not used for first bootstrap:
Xcode resolves local package binary targets before target build phases run, so
a build phase cannot repair a missing `RelayStreamGuestFFI.xcframework`.

## CI

The iOS workflow installs Rust stable when needed, then runs
`scripts/bootstrap-relay-stream-guest-ffi.sh` before any `xcodebuild`
invocation. That guarantees `binaryTarget(path:)` resolves in a clean checkout
without storing the 130 MB XCFramework in git.

## Clean Checkout Check

To simulate a clean checkout locally:

```sh
rm -rf Native/RelayStreamGuestFFI/RelayStreamGuestFFI.xcframework
RELAY_STREAM_GUEST_FFI_PROFILE=release scripts/bootstrap-relay-stream-guest-ffi.sh
xcodebuild \
  -project TerminalApp/Soyeht.xcodeproj \
  -scheme "Soyeht Dev" \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -skipPackagePluginValidation \
  build
```

The first command removes only the generated artifact. The bootstrap must
recreate it before `xcodebuild` resolves packages.
