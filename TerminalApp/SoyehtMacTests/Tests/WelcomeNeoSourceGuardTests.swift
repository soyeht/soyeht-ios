import XCTest

/// What the neo setup flow must keep true. Each of these was a real defect
/// before the rewrite, and each is invisible in a screenshot of the happy
/// path.
final class WelcomeNeoSourceGuardTests: XCTestCase {
    func test_theWindowAndItsRootAgreeOnOneSize() throws {
        let controller = try macSource("Welcome/WelcomeWindowController.swift")
        let root = try macSource("Welcome/WelcomeRootView.swift")
        XCTAssertTrue(controller.contains("NSSize(width: 720, height: 540)"))
        XCTAssertTrue(root.contains(".frame(width: 720, height: 540)"))
        XCTAssertTrue(
            controller.contains("NSAppearance(named: .aqua)"),
            "a dark titlebar over the light setup canvas reads as a rendering fault"
        )
    }

    func test_setupPinsItsOwnPaletteInsteadOfFollowingTheActiveStyle() throws {
        let root = try macSource("Welcome/WelcomeRootView.swift")
        XCTAssertTrue(root.contains("NeoPalette.cloud.canvas"))
        XCTAssertTrue(root.contains(".preferredColorScheme(.light)"))
        let scaffold = try macSource("Welcome/Neo/WelcomeStepScaffold.swift")
        XCTAssertTrue(scaffold.contains("private let palette = NeoPalette.cloud"))
    }

    func test_theInstallStepKeepsItsWorkAliveWhileAskingForPermission() throws {
        let source = try macSource("Welcome/Bootstrap/InstallProgressView.swift")
        let body = try slice(source, from: "var body: some View {", to: "private var phaseLabel:")
        XCTAssertTrue(
            body.contains(".task(id: installAttempt)"),
            "the install task must hang off the scaffold, not off a branch that disappears with the approval card"
        )
        let cardUse = try slice(body, from: "if approvalRequired {", to: "}")
        XCTAssertTrue(cardUse.contains("LoginItemsApprovalCard("))
        XCTAssertTrue(
            body.contains("NSApplication.didBecomeActiveNotification"),
            "coming back from System Settings is the signal to re-check"
        )
        XCTAssertTrue(source.contains("SMAppServiceInstaller.status"))
        XCTAssertFalse(
            source.contains("kickstart"),
            "only the installer nudges launchd; the progress step must not"
        )
    }

    func test_theStatusPollerCannotBeHeldOpenByASilentHost() throws {
        let source = try macSource("Welcome/Bootstrap/InstallProgressView.swift")
        let client = try slice(
            source,
            from: "private static func boundedStatusClient()",
            to: "@MainActor private func advance()"
        )
        XCTAssertTrue(client.contains("timeoutIntervalForRequest = 5"))
        XCTAssertTrue(client.contains("BootstrapStatusClient("))
    }

    func test_theMacNamesItsOwnHomeWithoutWaitingForAPhone() throws {
        let root = try macSource("Welcome/WelcomeRootView.swift")
        let route = try slice(
            root,
            from: "private func continueAfterInstallReady() async {",
            to: "private func continueAfterAgentsStep"
        )
        XCTAssertFalse(
            route.contains("SetupInvitationListener("),
            "waiting on a phone that is not running yet is what made a finished bar look hung"
        )
        XCTAssertTrue(route.contains("bootstrapPath.append(.houseNaming)"))
        XCTAssertTrue(route.contains("routeExistingEngineStateAfterInstall"))
    }

    func test_theRetiredPreviewStepIsGoneFromTheFlow() throws {
        let root = try macSource("Welcome/WelcomeRootView.swift")
        XCTAssertFalse(root.contains("installPreview"))
        XCTAssertFalse(root.contains("InstallPreviewView"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
