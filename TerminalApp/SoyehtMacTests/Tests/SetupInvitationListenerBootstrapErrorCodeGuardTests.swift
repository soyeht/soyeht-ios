import XCTest

/// Source-guard (text-scan): `SetupInvitationListener`'s claim-failure "proceed
/// anyway" decision must interpret the live codes via the typed `BootstrapErrorCode`
/// and keep the legacy (theyos@8effb506-no-longer-emitted) codes in a NAMED local
/// allowlist — never a bare untyped string list. `SetupInvitationListener` is app
/// code in a target the macOS domain tests don't link, so this guards the shape by
/// reading the source rather than calling the file-private function.
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

    func test_proceedAfterClaimFailure_typesLiveCodes_andNamesLegacyAllowlist() throws {
        let src = try setupInvitationListenerSource()

        // Live claim codes are interpreted via the typed BootstrapErrorCode.
        XCTAssertTrue(
            src.contains("BootstrapErrorCode(wire: code)"),
            "shouldProceedAfterClaimFailure must interpret the code via BootstrapErrorCode"
        )
        XCTAssertTrue(
            src.contains(".invitationNotRecognized") && src.contains(".alreadyInitialized"),
            "the live claim codes must be typed BootstrapErrorCode cases"
        )

        // Legacy codes live in a named, documented allowlist — not a bare string list.
        XCTAssertTrue(
            src.contains("legacyProceedAfterClaimFailureCodes"),
            "legacy claim codes must be in the named legacyProceedAfterClaimFailureCodes allowlist"
        )
        XCTAssertTrue(
            src.contains("\"invalid_state\"") && src.contains("\"already_named\""),
            "the two legacy codes (not in the BootstrapErrorCode fixture) must be in the allowlist"
        )
    }
}
