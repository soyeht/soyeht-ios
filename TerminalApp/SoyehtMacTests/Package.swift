// swift-tools-version:5.9
import PackageDescription

// Isolated SwiftPM package for Phase 1/2 domain-layer unit tests. Sources/SoyehtMacDomain/
// contains symlinks into ../SoyehtMac/Model, the AppKit-free Store files, and the
// pairing helpers that only depend on Foundation + SoyehtCore (PaneAttachRegistry).
// Runs with `swift test` from this directory.
//
// Platform floor is macOS 14 (minimum technical requirement for the @Observable
// macro used by the stores). The host app ships as macOS 15+ by product decision
// but the domain tests only need @Observable availability.
let package = Package(
    name: "SoyehtMacDomainTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/SoyehtCore"),
    ],
    targets: [
        .target(
            name: "SoyehtMacDomain",
            dependencies: [
                .product(name: "SoyehtCore", package: "SoyehtCore"),
            ]
        ),
        .testTarget(
            name: "SoyehtMacDomainTests",
            dependencies: [
                "SoyehtMacDomain",
                .product(name: "SoyehtCore", package: "SoyehtCore"),
            ],
            path: "Tests"
        ),
    ]
)
