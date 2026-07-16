import XCTest
@testable import SoyehtCore

/// Proves the dev/release install namespaces are fully disjoint — this is the
/// isolation invariant the whole `SoyehtInstallProfile` exists to guarantee.
final class SoyehtInstallProfileTests: XCTestCase {

    // MARK: - Resolution

    func test_resolve_shippingBundleID_isRelease() {
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "com.soyeht.mac"), .release)
    }

    func test_resolve_devBundleID_isDev() {
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "com.soyeht.mac.dev"), .dev)
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "com.soyeht.app.dev"), .dev)
        XCTAssertEqual(
            SoyehtInstallProfile.resolve(
                bundleIdentifier: "com.soyeht.app.dev.SoyehtClawShareTunnelProvider"
            ),
            .dev
        )
    }

    func test_resolve_unknownOrNil_defaultsToRelease() {
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: nil), .release)
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "com.soyeht.app"), .release)
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "com.example.dev.helper"), .release)
        XCTAssertEqual(SoyehtInstallProfile.resolve(bundleIdentifier: "org.tirania.SwiftTerm.iOSTerminalTests"), .release)
    }

    // MARK: - Exact values (release must never drift — shipping footprint)

    func test_releaseProfile_matchesHistoricalConstants() {
        let p = SoyehtInstallProfile.release
        XCTAssertEqual(p.supportDirectoryName, "Soyeht")
        XCTAssertEqual(p.dotTheyosName, ".theyos")
        XCTAssertEqual(p.engineLaunchAgentPlistName, "com.soyeht.engine.plist")
        XCTAssertEqual(p.engineLaunchdLabel, "com.soyeht.engine")
        XCTAssertEqual(p.keychainService, "com.soyeht.mac")
        XCTAssertEqual(p.mobileKeychainService, "com.soyeht.mobile")
        XCTAssertEqual(p.householdKeychainService, "com.soyeht.household")
        XCTAssertEqual(p.householdOwnerKeyPrefix, "com.soyeht.household.owner")
        XCTAssertEqual(p.adminPort, 8892)
        XCTAssertEqual(p.bootstrapPort, 8091)
        XCTAssertEqual(p.adminHost, "localhost:8892")
        XCTAssertEqual(p.bootstrapHost, "localhost:8091")
        XCTAssertEqual(p.engineLogPath, "/tmp/soyeht-engine.log")
    }

    func test_devProfile_isFullyNamespaced() {
        let p = SoyehtInstallProfile.dev
        XCTAssertEqual(p.supportDirectoryName, "SoyehtDev")
        XCTAssertEqual(p.dotTheyosName, ".theyos-dev")
        XCTAssertEqual(p.engineLaunchAgentPlistName, "com.soyeht.engine.dev.plist")
        XCTAssertEqual(p.engineLaunchdLabel, "com.soyeht.engine.dev")
        XCTAssertEqual(p.keychainService, "com.soyeht.mac.dev")
        XCTAssertEqual(p.mobileKeychainService, "com.soyeht.mobile.dev")
        XCTAssertEqual(p.householdKeychainService, "com.soyeht.household.dev")
        XCTAssertEqual(p.householdOwnerKeyPrefix, "com.soyeht.household.dev.owner")
        XCTAssertEqual(p.adminPort, 8902)
        XCTAssertEqual(p.bootstrapPort, 8101)
        XCTAssertEqual(p.adminHost, "localhost:8902")
        XCTAssertEqual(p.bootstrapHost, "localhost:8101")
        XCTAssertEqual(p.engineLogPath, "/tmp/soyehtdev-engine.log")
    }

    // MARK: - The isolation invariant

    func test_devAndRelease_shareNoNamespacedValue() {
        let release = Set(SoyehtInstallProfile.release.namespacedValues)
        let dev = Set(SoyehtInstallProfile.dev.namespacedValues)
        XCTAssertTrue(
            release.isDisjoint(with: dev),
            "dev and release must not share ANY namespaced identifier; overlap = \(release.intersection(dev))"
        )
    }

    func test_everyNamespacedField_differsPairwise() {
        let r = SoyehtInstallProfile.release
        let d = SoyehtInstallProfile.dev
        // Field-by-field so a regression names the exact leaking field.
        XCTAssertNotEqual(r.supportDirectoryName, d.supportDirectoryName)
        XCTAssertNotEqual(r.dotTheyosName, d.dotTheyosName)
        XCTAssertNotEqual(r.engineLaunchAgentPlistName, d.engineLaunchAgentPlistName)
        XCTAssertNotEqual(r.engineLaunchdLabel, d.engineLaunchdLabel)
        XCTAssertNotEqual(r.keychainService, d.keychainService)
        XCTAssertNotEqual(r.mobileKeychainService, d.mobileKeychainService)
        XCTAssertNotEqual(r.householdKeychainService, d.householdKeychainService)
        XCTAssertNotEqual(r.householdOwnerKeyPrefix, d.householdOwnerKeyPrefix)
        XCTAssertFalse(
            d.householdOwnerKeyPrefix.hasPrefix(r.householdOwnerKeyPrefix + "."),
            "dev owner-key tags must not match release prefix-scoped deletes"
        )
        XCTAssertNotEqual(r.adminPort, d.adminPort)
        XCTAssertNotEqual(r.bootstrapPort, d.bootstrapPort)
        XCTAssertNotEqual(r.engineLogPath, d.engineLogPath)
    }

    func test_allPortsDistinctAcrossProfiles() {
        let ports = [
            SoyehtInstallProfile.release.adminPort,
            SoyehtInstallProfile.release.bootstrapPort,
            SoyehtInstallProfile.dev.adminPort,
            SoyehtInstallProfile.dev.bootstrapPort,
        ]
        XCTAssertEqual(Set(ports).count, ports.count, "every admin/bootstrap port must be unique so the two engines can coexist")
    }

    /// The dev support dir name must not be a prefix-collision that resolves to
    /// the same Application Support folder as release (it contains "Soyeht" as a
    /// substring, but must be a distinct directory).
    func test_devSupportDir_isDistinctDirectory_notReleaseSubpath() {
        XCTAssertNotEqual(SoyehtInstallProfile.dev.supportDirectoryName, SoyehtInstallProfile.release.supportDirectoryName)
        XCTAssertFalse(SoyehtInstallProfile.dev.supportDirectoryName.hasPrefix("Soyeht/"))
    }

    // MARK: - Engine-command ownership (no cross-build force-kill)

    func test_ownsEngineCommand_matchesOnlyOwnBuild() {
        // What `ps` shows for the exec'd engine (resolved binary path)…
        let releaseExec = "/Users/x/Library/Application Support/Soyeht/engine/theyos-engine"
        let devExec = "/Users/x/Library/Application Support/SoyehtDev/engine/theyos-engine"
        // …and for the pre-exec shell wrapper (the plist ProgramArguments).
        let releaseShell = #"SOYEHT_DIR="$HOME/Library/Application Support/Soyeht"; ENGINE_DIR="$SOYEHT_DIR/engine"; export THEYOS_BIN_DIR="$ENGINE_DIR"; exec "$ENGINE_DIR/theyos-engine""#
        let devShell = #"SOYEHT_DIR="$HOME/Library/Application Support/SoyehtDev"; ENGINE_DIR="$SOYEHT_DIR/engine"; export THEYOS_BIN_DIR="$ENGINE_DIR"; exec "$ENGINE_DIR/theyos-engine""#

        let release = SoyehtInstallProfile.release
        let dev = SoyehtInstallProfile.dev

        // Each profile owns its own build's command, exec'd and shell forms.
        XCTAssertTrue(release.ownsEngineCommand(releaseExec))
        XCTAssertTrue(release.ownsEngineCommand(releaseShell))
        XCTAssertTrue(dev.ownsEngineCommand(devExec))
        XCTAssertTrue(dev.ownsEngineCommand(devShell))

        // And NEVER the other build's — "Soyeht" must not prefix-match
        // "SoyehtDev". This is the force-kill / wait-for-exit hazard.
        XCTAssertFalse(release.ownsEngineCommand(devExec), "release must not claim the dev engine")
        XCTAssertFalse(release.ownsEngineCommand(devShell), "release must not claim the dev shell wrapper")
        XCTAssertFalse(dev.ownsEngineCommand(releaseExec), "dev must not claim the shipping engine")
        XCTAssertFalse(dev.ownsEngineCommand(releaseShell), "dev must not claim the shipping shell wrapper")

        // The shared THEYOS_BIN_DIR="$ENGINE_DIR" fragment must NOT be enough to match.
        XCTAssertFalse(release.ownsEngineCommand(#"export THEYOS_BIN_DIR="$ENGINE_DIR""#))
        XCTAssertFalse(dev.ownsEngineCommand(#"export THEYOS_BIN_DIR="$ENGINE_DIR""#))
    }

    // MARK: - Cross-repo engine port contract

    /// The release profile's ports are not free parameters: they are the client
    /// half of a cross-repo contract with the theyos engine. `bootstrapPort` must
    /// equal the engine's household default (`server_rs::household_bootstrap::`
    /// `DEFAULT_HOUSEHOLD_PORT` = 8091) and `adminPort` must equal the engine's
    /// `ADMIN_PORT` = 8892. Both values are documented in theyos `PORTS.md`, whose
    /// agreement with the engine constants is pinned by theyos's `ports_registry`
    /// test. If theyos moves an engine port, this test (and that one) must move in
    /// lockstep — that is the point.
    func test_releasePorts_matchTheyosEngineContract() {
        // Keep these literals in sync with theyos PORTS.md / DEFAULT_HOUSEHOLD_PORT.
        let theyosHouseholdPort = 8091
        let theyosAdminPort = 8892
        XCTAssertEqual(
            SoyehtInstallProfile.release.bootstrapPort, theyosHouseholdPort,
            "iOS bootstrapPort must equal the theyos engine THEYOS_HOUSEHOLD_PORT default"
        )
        XCTAssertEqual(
            SoyehtInstallProfile.release.adminPort, theyosAdminPort,
            "iOS adminPort must equal the theyos engine ADMIN_PORT"
        )
    }
}
