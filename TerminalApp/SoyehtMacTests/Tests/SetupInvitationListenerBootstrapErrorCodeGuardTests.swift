import XCTest

/// The app target must not reinstate the old claim-failure success path.
final class SetupInvitationListenerBootstrapErrorCodeGuardTests: XCTestCase {
    private func setupInvitationListenerSource() throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent(
            "SoyehtMac/Welcome/SetupInvitationListener/SetupInvitationListener.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testClaimFailureCannotBecomeSuccessfulNotification() throws {
        let source = try setupInvitationListenerSource()
        XCTAssertFalse(source.contains("shouldProceedAfterClaimFailure"))
        XCTAssertFalse(source.contains("legacyProceedAfterClaimFailureCodes"))
        XCTAssertTrue(source.contains("event = .existingHouseOffered"))
        XCTAssertTrue(source.contains("event = .bootstrapClaimAccepted"))
        XCTAssertTrue(source.contains("SetupInvitationCeremony.requireMatchingHouse"))
        let claim = try XCTUnwrap(source.range(of: "try await claimWithRetry(hit: hit)"))
        let success = try XCTUnwrap(source.range(of: "event = .bootstrapClaimAccepted"))
        XCTAssertLessThan(claim.lowerBound, success.lowerBound)
        XCTAssertTrue(source.contains("try hit.payload.requireInstallation(.current)"))
    }
}
