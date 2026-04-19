// swift-tools-version:5.9
import PackageDescription

// Isolated SwiftPM package for Phase 1/2 domain-layer unit tests. Sources/SoyehtMacDomain/
// contains symlinks into ../MacTerminal/Model, the AppKit-free Store files, and the
// pairing helpers that only depend on Foundation + SoyehtCore (PaneAttachRegistry).
// Runs with `swift test` from this directory.
let package = Package(
    name: "SoyehtMacDomainTests",
    platforms: [.macOS(.v13)],
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
