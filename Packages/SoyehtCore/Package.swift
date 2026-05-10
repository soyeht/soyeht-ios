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
        .executable(name: "banned-vocab-audit", targets: ["BannedVocabAudit"]),
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
        .executableTarget(
            name: "BannedVocabAudit",
            dependencies: ["SoyehtCore"],
            path: "Sources/BannedVocabAudit"
        ),
        .testTarget(
            name: "SoyehtCoreTests",
            dependencies: ["SoyehtCore"],
            path: "Tests/SoyehtCoreTests",
            exclude: [
                "HouseholdFixtures/README.md",
                "HouseholdFixtures/MachineJoin/README.md",
                "HouseholdFixtures/OwnerCert/README.md",
                "HouseholdFixtures/Avatar/README.md",
            ],
            // SPM `.copy(file)` flattens the file to the test bundle's root —
            // the subdirectory is NOT preserved. The corresponding lookup in
            // `OperatorFingerprintTests.loadCrossRepoVectors()` therefore calls
            // `Bundle.module.url(forResource:withExtension:)` WITHOUT a
            // `subdirectory:` argument. Renaming the file, adding a sibling
            // with the same basename, or migrating to `.process` MUST be done
            // in lockstep with that lookup or the test will fail at runtime
            // with a misleading nil URL (no compile-time signal).
            // Same note applies to T039d/T039e fixtures: avatar-derivation-fixtures.csv
            // and owner-cert-auth.cbor are looked up without subdirectory prefix.
            resources: [
                .copy("HouseholdFixtures/MachineJoin/fingerprint_vectors.json"),
            ]
        ),
    ]
)
