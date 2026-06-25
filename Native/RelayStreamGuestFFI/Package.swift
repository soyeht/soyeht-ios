// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelayStreamGuestFFI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RelayStreamGuestFFI", targets: ["RelayStreamGuestFFI"]),
    ],
    targets: [
        .binaryTarget(
            name: "RelayStreamGuestFFIBinary",
            path: "RelayStreamGuestFFI.xcframework"
        ),
        .target(
            name: "relay_stream_guest_ffiFFI",
            path: "Sources/relay_stream_guest_ffiFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RelayStreamGuestFFI",
            dependencies: [
                "relay_stream_guest_ffiFFI",
                "RelayStreamGuestFFIBinary",
            ],
            path: ".",
            exclude: [
                ".build",
                "Cargo.lock",
                "Cargo.toml",
                "Generated/relay_stream_guest_ffiFFI.h",
                "Generated/relay_stream_guest_ffiFFI.modulemap",
                "RelayStreamGuestFFI.xcframework",
                "Scripts",
                "Smoke",
                "Sources",
                "SwiftTests",
                "src",
                "target",
            ],
            sources: [
                "Generated/relay_stream_guest_ffi.swift",
                "Swift/RelayStreamGuestDataPlaneClient.swift",
            ]
        ),
        .executableTarget(
            name: "RelayStreamGuestFFISmoke",
            dependencies: ["RelayStreamGuestFFI"],
            path: "Smoke"
        ),
    ]
)
