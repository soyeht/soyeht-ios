// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoyehtCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SoyehtCore", targets: ["SoyehtCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/JoshBashed/blake3-swift.git", exact: "0.2.2"),
    ],
    targets: [
        .target(
            name: "SoyehtCore",
            dependencies: [
                .product(name: "BLAKE3", package: "blake3-swift"),
            ],
            path: "Sources/SoyehtCore",
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Wordlists"),
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .testTarget(
            name: "SoyehtCoreTests",
            dependencies: ["SoyehtCore"],
            path: "Tests/SoyehtCoreTests",
            exclude: [
                "HouseholdFixtures/README.md",
                "HouseholdFixtures/MachineJoin/README.md",
            ],
            resources: [
                .copy("HouseholdFixtures/MachineJoin/fingerprint_vectors.json"),
            ]
        ),
    ]
)
