// swift-tools-version: 5.9
import PackageDescription

// Local SwiftPM package that wraps the prebuilt `ClawShareBridge`
// XCFramework (Rust `claw-share-bridge-rs`, UniFFI library mode).
//
// The XCFramework + the generated `Sources/ClawShareBridge/ClawShareBridge.swift`
// are produced by `admin/rust/claw-share-bridge-rs/build-xcframework.sh` in
// the theyos repo and committed here verbatim. See
// docs/claw-share-bridge-consumption.md for the refresh procedure and
// the provenance recorded in `ClawShareBridge.buildinfo.json`.
//
// This package is deliberately NOT a dependency of the SoyehtCore
// package: SoyehtCore (and its `swift test`) stay bridge-free so the
// `ClawShareDataPlaneClient` protocol + the `PendingDataPlaneClient`
// fallback compile without the binary. Only the host app and the
// `SoyehtClawShareTunnelProvider` extension link this product, which is
// what makes `#if canImport(ClawShareBridge)` select the real client.
let package = Package(
    name: "ClawShareBridge",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ClawShareBridge", targets: ["ClawShareBridge"]),
    ],
    targets: [
        .binaryTarget(
            name: "ClawShareBridgeFFI",
            path: "ClawShareBridge.xcframework"
        ),
        .target(
            name: "ClawShareBridge",
            dependencies: ["ClawShareBridgeFFI"],
            path: "Sources/ClawShareBridge"
        ),
        .testTarget(
            name: "ClawShareBridgeTests",
            dependencies: ["ClawShareBridge"],
            path: "Tests/ClawShareBridgeTests"
        ),
    ]
)
