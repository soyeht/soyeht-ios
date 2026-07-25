import XCTest

/// Source-guard (text-scan): `LocalPairingConnectionBadge` is app code in
/// `PreferencesDevicesViewController.swift`, a target the macOS domain tests
/// don't link (see `SetupInvitationListenerBootstrapErrorCodeGuardTests` for
/// the same pattern), so this guards the shape by reading the source rather
/// than calling the type directly.
///
/// Task #34 scope: a LOCAL, non-authoritative "Paired iPhone connected to
/// this Mac" badge fed only by `PairingPresenceServer.hasConnectedDevices` /
/// `membershipDidChangeNotification`. It must never become a household
/// identity, roster, remote-presence, membership, authority, route, or
/// `VerifiedMesh` signal.
final class LocalPairingConnectionBadgeSourceGuardTests: XCTestCase {
    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }

    private func fullSource() throws -> String {
        try macSource("SoyehtMac/PreferencesDevicesViewController.swift")
    }

    /// The declaration itself, deliberately excluding the doc comment above
    /// it (which discusses DeviceCert/roster/membership/etc. in prose) so
    /// word-containment checks below are unambiguous.
    private func badgeDeclaration() throws -> String {
        try slice(
            try fullSource(),
            from: "enum LocalPairingConnectionBadge: Equatable {",
            to: "@MainActor\nfinal class DevicesPreferencesViewController"
        )
    }

    func test_badgeInitializerAcceptsOnlyABareBool() throws {
        let decl = try badgeDeclaration()

        XCTAssertTrue(
            decl.contains("init(hasConnectedDevices: Bool)"),
            "The only initializer must take a bare Bool -- structurally incapable of accepting a DeviceCert, d_id, or roster/membership record."
        )
        XCTAssertTrue(decl.contains(".connected") && decl.contains(".notConnected"))
    }

    func test_badgeDeclarationNeverReferencesHouseholdOrDeviceIdentityTypes() throws {
        let decl = try badgeDeclaration()

        for forbidden in [
            "DeviceCert", "d_id", "MachineCert", "household", "Household",
            "roster", "Roster", "membership", "Membership",
            "VerifiedMesh", "authority", "Authority", "route", "Route",
        ] {
            XCTAssertFalse(
                decl.contains(forbidden),
                "LocalPairingConnectionBadge's declaration must never reference \(forbidden)."
            )
        }
    }

    func test_devicesPreferencesViewControllerObservesOnlyLocalPresenceNotification() throws {
        let source = try fullSource()

        XCTAssertTrue(source.contains(
            "name: PairingPresenceServer.membershipDidChangeNotification, object: nil"
        ))
        XCTAssertTrue(source.contains("selector: #selector(presenceMembershipChanged)"))
        XCTAssertTrue(source.contains("PairingPresenceServer.shared.hasConnectedDevices"))
        XCTAssertTrue(source.contains("NotificationCenter.default.removeObserver(self)"),
            "The observer must be torn down in deinit.")
    }

    func test_badgeCopyNamesLocalConnectionNotHouseholdPresence() throws {
        let decl = try badgeDeclaration()

        XCTAssertTrue(decl.contains("Paired iPhone connected to this Mac"))
        XCTAssertTrue(decl.contains("No paired iPhone currently connected"))
    }
}
