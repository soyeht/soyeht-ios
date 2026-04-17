// swift-tools-version:5.9
import PackageDescription

// Isolated SwiftPM package for Phase 1 domain-layer unit tests. Sources/SoyehtMacDomain/
// contains symlinks into ../MacTerminal/Model and the two AppKit-free Store files.
// Runs with `swift test` from this directory.
let package = Package(
    name: "SoyehtMacDomainTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SoyehtMacDomain"),
        .testTarget(
            name: "SoyehtMacDomainTests",
            dependencies: ["SoyehtMacDomain"],
            path: "Tests"
        ),
    ]
)
