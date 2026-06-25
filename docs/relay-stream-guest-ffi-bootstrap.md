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
- Network access for Cargo to resolve the pinned theyos dependency.

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
