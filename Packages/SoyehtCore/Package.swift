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
            // subdirectory is NOT preserved. Lookups must omit the subdirectory
            // argument (see OperatorFingerprintTests, HouseAvatarDerivationTests).
            // Exception: `.copy("Fixtures")` copies the whole directory, so
            // bundle.url(forResource:withExtension:subdirectory:"Fixtures/push")
            // works for CasaNasceuPushPayloadTests.
            // Any rename or migration to .process MUST be done in lockstep with
            // the corresponding Bundle.module.url call — no compile-time signal.
            resources: [
                // T039d — operator fingerprint cross-language fixture (Rust→Swift)
                .copy("HouseholdFixtures/MachineJoin/fingerprint_vectors.json"),
                // T039d — owner-cert CBOR cross-language fixture
                .copy("HouseholdFixtures/OwnerCert/owner_cert_auth.cbor"),
                // T039e — avatar derivation cross-language fixture (1 000 rows)
                .copy("HouseholdFixtures/Avatar/avatar-derivation-fixtures.csv"),
                // FR-045 — emoji security code cross-language fixtures
                .copy("HouseholdFixtures/EmojiSecurityCode/emoji-security-code-fixtures.csv"),
                .copy("HouseholdFixtures/EmojiSecurityCode/emoji-security-code-wordlist.csv"),
                // T067b — casa_nasceu push payload cross-language fixture
                // Accessible at subdirectory:"Fixtures/push" (directory copy preserves structure)
                .copy("Fixtures"),
            ]
        ),
    ]
)
