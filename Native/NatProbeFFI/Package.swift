// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NatProbeFFI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NatProbeFFI", targets: ["NatProbeFFI"]),
    ],
    targets: [
        .binaryTarget(
            name: "NatProbeFFIBinary",
            path: "NatProbeFFI.xcframework"
        ),
        .target(
            name: "nat_probe_ffiFFI",
            path: "Sources/nat_probe_ffiFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NatProbeFFI",
            dependencies: [
                "nat_probe_ffiFFI",
                "NatProbeFFIBinary",
            ],
            path: ".",
            exclude: [
                ".build",
                "Cargo.lock",
                "Cargo.toml",
                "Generated/nat_probe_ffiFFI.h",
                "Generated/nat_probe_ffiFFI.modulemap",
                "NatProbeFFI.xcframework",
                "Scripts",
                "Smoke",
                "Sources",
                "src",
                "target",
            ],
            sources: [
                "Generated/nat_probe_ffi.swift",
            ]
        ),
        .executableTarget(
            name: "NatProbeFFISmoke",
            dependencies: ["NatProbeFFI"],
            path: "Smoke"
        ),
    ]
)
