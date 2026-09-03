import XCTest

/// What has to be true for a Mac to leave the Welcome window in a usable
/// state: it owns a credential for its own engine, the main window opens with
/// a live shell, and a relaunch goes straight to that window.
final class WelcomeHandoffSourceGuardTests: XCTestCase {
    func test_everyExitFromTheHouseCardMintsTheCredentialBeforeNavigating() throws {
        let houseCard = try macSource("Welcome/Bootstrap/HouseCardView.swift")
        let poll = try slice(
            houseCard,
            from: "private func pollUntilPaired() async {",
            to: "private func listenForIPhoneInvitations("
        )
        let readyBranch = try slice(poll, from: "case .ready:", to: "case .namedAwaitingPair")
        let mint = try XCTUnwrap(readyBranch.range(of: "await onContinueOnMac()"))
        let navigate = try XCTUnwrap(readyBranch.range(of: "onPaired()"))
        XCTAssertTrue(
            mint.lowerBound < navigate.lowerBound,
            "the credential must exist before the main window is asked for"
        )

        let button = try slice(
            houseCard,
            from: "private func continueOnMac() {",
            to: "private static func securityCodeWords("
        )
        XCTAssertTrue(button.contains("if error == nil { onPaired() }"))
    }

    func test_theCredentialIsMintedThroughTheVerifiedLocalEnginePath() throws {
        let welcome = try macSource("Welcome/WelcomeRootView.swift")
        let ensure = try slice(
            welcome,
            from: "private func ensureLocalCredential() async -> LocalizedStringResource? {",
            to: "private static let continueFailedMessage"
        )
        XCTAssertTrue(
            ensure.contains("LocalEngineContext.resolveDetailed()"),
            "resolveDetailed records the verified server id, so the first pane never self-pairs a second time"
        )
        XCTAssertFalse(ensure.contains("TheyOSAutoPairService().autoPair()"))
        XCTAssertTrue(ensure.contains("case .engineNotAnsweringYet:"), "a booting engine is not a broken Mac")
        XCTAssertFalse(ensure.contains("onPaired()"), "minting must not navigate; its callers do")
    }

    func test_finishingWelcomeOpensTheFirstShell() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let finish = try slice(appDelegate, from: "private func finishWelcome() {", to: "\n    }")
        XCTAssertTrue(finish.contains("openNewMainWindow()"))
        XCTAssertTrue(finish.contains("openFirstShellPaneIfEmpty()"))
    }

    func test_theFirstShellNeverGreetsTheOwnerWithAnAlert() throws {
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let opener = try slice(
            controller,
            from: "func openFirstShellPaneIfEmpty() {",
            to: "\n    }"
        )
        XCTAssertTrue(opener.contains("presentation: .retryThenPicker"))
        XCTAssertTrue(opener.contains(".placeholderMirror"))

        let start = try slice(
            controller,
            from: "func startLocalShell(",
            to: "func openFirstShellPaneIfEmpty()"
        )
        let retryBranch = try slice(start, from: "case .retryThenPicker:", to: "\n                }")
        XCTAssertFalse(
            retryBranch.contains("presentLocalPTYError"),
            "the onboarding pane retries quietly and leaves the picker; it must never raise a modal"
        )
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
