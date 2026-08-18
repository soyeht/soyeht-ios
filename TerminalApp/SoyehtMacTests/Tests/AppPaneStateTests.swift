import XCTest
@testable import SoyehtMacDomain

final class AppPaneStateTests: XCTestCase {
    func testAppContentRoundTrips() throws {
        let content = PaneContent.app(AppPaneState(
            installID: "inst-01",
            appID: "sys-monitor",
            name: "System Monitor"
        ))

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)

        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.kind, .app)
        XCTAssertEqual(decoded.displayKind, "app")
        XCTAssertNil(decoded.primaryPath, "app panes must not report install layout as a path")
        XCTAssertEqual(decoded.matchingKey, "app:inst-01")
    }

    func testAppContentRoundTripsWithoutName() throws {
        let content = PaneContent.app(AppPaneState(installID: "inst-02", appID: "sys-monitor"))

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)

        XCTAssertEqual(decoded, content)
        guard case .app(let state) = decoded else {
            return XCTFail("Expected app content")
        }
        XCTAssertNil(state.name)
    }

    /// Identity is the INSTALLATION id, not the app id: a reinstall (new
    /// installID, same appID) must be a new pane identity so Phase 2c grants
    /// are never silently inherited by code that may differ.
    func testAppMatchingKeyUsesInstallIDNotAppID() {
        let first = PaneContent.app(AppPaneState(installID: "inst-01", appID: "sys-monitor"))
        let reinstalled = PaneContent.app(AppPaneState(installID: "inst-02", appID: "sys-monitor"))

        XCTAssertNotEqual(first.matchingKey, reinstalled.matchingKey)
    }

    /// The Phase 1 lesson: identity must not derive from mutable state.
    /// A display rename changes nothing about which pane this is.
    func testAppMatchingKeyStableWhenNameChanges() {
        let before = PaneContent.app(AppPaneState(installID: "inst-01", appID: "sys-monitor", name: "Old"))
        let after = PaneContent.app(AppPaneState(installID: "inst-01", appID: "sys-monitor", name: "New"))

        XCTAssertEqual(before.matchingKey, after.matchingKey)
    }

    func testAppMatchingKeyDoesNotCollideWithOtherKinds() {
        let app = PaneContent.app(AppPaneState(installID: "x", appID: "sys-monitor"))
        let web = PaneContent.web(WebPaneState(anchorURL: "https://example.com"))
        let editor = PaneContent.editor(EditorPaneState(rootPath: "/tmp/project"))
        let git = PaneContent.git(GitPaneState(repoPath: "/tmp/project"))
        let terminal = PaneContent.terminal(TerminalPaneState())

        let keys = [app, web, editor, git, terminal].map(\.matchingKey)
        XCTAssertEqual(Set(keys).count, keys.count, "kind sentinels must keep matchingKeys disjoint")
    }

    /// Third-party display data is capped at 128 Unicode SCALARS on entry
    /// (precedent: ShareableAppPresentation.nameMaxChars). Combining-mark
    /// padding must not smuggle an over-long name past the limit, so the
    /// cap counts scalars, not grapheme clusters.
    func testAppNameIsCappedAt128UnicodeScalars() {
        let padded = "a" + String(repeating: "\u{0301}", count: 500)
        let state = AppPaneState(installID: "inst-01", appID: "sys-monitor", name: padded)

        XCTAssertEqual(state.name?.unicodeScalars.count, AppPaneState.nameMaxScalars)
    }

    func testAppNameCapAppliesOnDecode() throws {
        let longName = String(repeating: "x", count: 300)
        let json = """
        {
          "kind": "app",
          "app": { "installID": "inst-01", "appID": "sys-monitor", "name": "\(longName)" }
        }
        """

        let decoded = try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8))

        guard case .app(let state) = decoded else {
            return XCTFail("Expected app content")
        }
        XCTAssertEqual(state.name?.unicodeScalars.count, AppPaneState.nameMaxScalars)
    }

    func testAppStateDecodesWithoutName() throws {
        let json = """
        {
          "kind": "app",
          "app": { "installID": "inst-01", "appID": "sys-monitor" }
        }
        """

        let decoded = try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8))

        guard case .app(let state) = decoded else {
            return XCTFail("Expected app content")
        }
        XCTAssertNil(state.name)
    }

    /// The wire `path` field has ONE producer (contract rule born of the
    /// path-empty defect): every automation consumer reads
    /// `automationReportPath`, so no site can diverge by omission.
    func testAutomationReportPathIsTheSingleWireProducer() {
        let app = PaneContent.app(AppPaneState(installID: "inst-01", appID: "sys-monitor"))
        XCTAssertEqual(app.automationReportPath, "app:sys-monitor")

        let web = PaneContent.web(WebPaneState(
            anchorURL: "https://example.com",
            url: "https://example.com/navigated"
        ))
        XCTAssertEqual(web.automationReportPath, "https://example.com/navigated")

        let editor = PaneContent.editor(EditorPaneState(rootPath: "/tmp/project"))
        XCTAssertEqual(editor.automationReportPath, "/tmp/project")

        XCTAssertNil(PaneContent.terminal(TerminalPaneState()).automationReportPath)
    }
}
