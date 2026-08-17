import XCTest
@testable import SoyehtMacDomain

final class PaneContentTests: XCTestCase {
    func testLegacyConversationWithoutContentDecodesAsTerminal() throws {
        let id = UUID()
        let workspaceID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "handle": "@legacy",
          "agent": "shell",
          "workspaceID": "\(workspaceID.uuidString)",
          "commander": { "mirror": { "instanceID": "pending" } }
        }
        """

        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))

        XCTAssertEqual(conversation.id, id)
        XCTAssertEqual(conversation.workspaceID, workspaceID)
        XCTAssertEqual(conversation.content, .terminal(TerminalPaneState()))
    }

    func testEditorContentRoundTrips() throws {
        let content = PaneContent.editor(EditorPaneState(
            rootPath: "/tmp/project",
            selectedFilePath: "/tmp/project/README.md",
            selectedLine: 12,
            selectedColumn: 3,
            openFilePaths: ["/tmp/project/README.md"]
        ))

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)

        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.kind, .editor)
        XCTAssertEqual(decoded.primaryPath, "/tmp/project/README.md")
    }

    func testEditorContentDefaultsProjectExpandedForLegacyPayload() throws {
        let json = """
        {
          "kind": "editor",
          "editor": {
            "rootPath": "/tmp/project",
            "selectedFilePath": "/tmp/project/README.md",
            "selectedLine": 12,
            "selectedColumn": 3,
            "openFilePaths": ["/tmp/project/README.md"]
          }
        }
        """

        let decoded = try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8))

        guard case .editor(let state) = decoded else {
            return XCTFail("Expected editor content")
        }
        XCTAssertTrue(state.isProjectExpanded)
    }

    func testEditorMatchingKeyIgnoresCursorPosition() {
        let a = PaneContent.editor(EditorPaneState(
            rootPath: "/tmp/project",
            selectedFilePath: "/tmp/project/README.md",
            selectedLine: 1
        ))
        let b = PaneContent.editor(EditorPaneState(
            rootPath: "/tmp/project",
            selectedFilePath: "/tmp/project/README.md",
            selectedLine: 99
        ))

        XCTAssertEqual(a.matchingKey, b.matchingKey)
    }

    func testEditorMatchingKeyUsesRootForPaneReuse() {
        let readme = PaneContent.editor(EditorPaneState(
            rootPath: "/tmp/project",
            selectedFilePath: "/tmp/project/README.md"
        ))
        let app = PaneContent.editor(EditorPaneState(
            rootPath: "/tmp/project",
            selectedFilePath: "/tmp/project/Sources/App.swift"
        ))

        XCTAssertEqual(readme.matchingKey, app.matchingKey)
    }

    func testGitMatchingKeyUsesRepoForPaneReuse() {
        let status = PaneContent.git(GitPaneState(repoPath: "/tmp/project"))
        let file = PaneContent.git(GitPaneState(repoPath: "/tmp/project", selectedFilePath: "Sources/App.swift"))

        XCTAssertEqual(status.matchingKey, file.matchingKey)
        XCTAssertEqual(file.primaryPath, "/tmp/project")
    }

    // MARK: - Web pane (Phase 1)

    func testWebContentRoundTrips() throws {
        let content = PaneContent.web(WebPaneState(
            anchorURL: "https://example.com/docs",
            url: "https://example.com/docs/guide",
            title: "Guide"
        ))

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)

        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.kind, .web)
        XCTAssertEqual(decoded.displayKind, "web")
        XCTAssertEqual(decoded.primaryPath, nil, "web panes must not report a path")
        XCTAssertEqual(decoded.matchingKey, "web:https://example.com/docs")
    }

    func testWebContentRoundTripsWithoutTitle() throws {
        let content = PaneContent.web(WebPaneState(anchorURL: "https://example.com"))

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)

        XCTAssertEqual(decoded, content)
        guard case .web(let state) = decoded else {
            return XCTFail("Expected web content")
        }
        XCTAssertNil(state.title)
        XCTAssertEqual(state.url, "https://example.com", "url defaults to anchorURL")
    }

    func testWebStateDecodesWithMissingURLFallingBackToAnchor() throws {
        let json = """
        {
          "kind": "web",
          "web": { "anchorURL": "https://example.com/legacy" }
        }
        """

        let decoded = try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8))

        guard case .web(let state) = decoded else {
            return XCTFail("Expected web content")
        }
        XCTAssertEqual(state.url, "https://example.com/legacy")
        XCTAssertNil(state.title)
    }

    /// The anchorURL correction: navigation updates only `url`/`title`.
    /// Identity (matchingKey) must be stable across those writes, otherwise
    /// every navigation rebuilds the WKWebView instead of updating in place.
    func testWebMatchingKeyStableWhenOnlyURLAndTitleChange() {
        let fresh = PaneContent.web(WebPaneState(anchorURL: "https://example.com/docs"))
        let navigated = PaneContent.web(WebPaneState(
            anchorURL: "https://example.com/docs",
            url: "https://example.com/docs/guide?page=3",
            title: "Guide — Example"
        ))

        XCTAssertEqual(fresh.matchingKey, navigated.matchingKey)
    }

    func testWebMatchingKeyIgnoresSchemeHostCase() {
        let lowercase = PaneContent.web(WebPaneState(anchorURL: "https://example.com/Docs"))
        let uppercase = PaneContent.web(WebPaneState(anchorURL: "HTTPS://EXAMPLE.COM/Docs"))

        XCTAssertEqual(lowercase.matchingKey, uppercase.matchingKey)
    }

    func testWebMatchingKeyIgnoresFragment() {
        let plain = PaneContent.web(WebPaneState(anchorURL: "https://example.com/docs"))
        let fragged = PaneContent.web(WebPaneState(anchorURL: "https://example.com/docs#section"))

        XCTAssertEqual(plain.matchingKey, fragged.matchingKey)
    }

    /// Distinct resources must keep distinct identities: canonical() only
    /// equates the origin empty-path form, never general trailing slashes.
    func testWebMatchingKeyDistinguishesDistinctResources() {
        let root = PaneContent.web(WebPaneState(anchorURL: "https://example.com"))
        let path = PaneContent.web(WebPaneState(anchorURL: "https://example.com/app"))
        let trailing = PaneContent.web(WebPaneState(anchorURL: "https://example.com/app/"))
        let query = PaneContent.web(WebPaneState(anchorURL: "https://example.com/app?v=2"))
        let port = PaneContent.web(WebPaneState(anchorURL: "https://example.com:8443/app"))

        let keys = [root, path, trailing, query, port].map(\.matchingKey)
        XCTAssertEqual(Set(keys).count, keys.count, "distinct resources must not share a matchingKey")
    }

    func testWebMatchingKeyDoesNotCollideWithOtherKinds() {
        let web = PaneContent.web(WebPaneState(anchorURL: "/tmp/project"))
        let editor = PaneContent.editor(EditorPaneState(rootPath: "/tmp/project"))
        let git = PaneContent.git(GitPaneState(repoPath: "/tmp/project"))
        let terminal = PaneContent.terminal(TerminalPaneState())

        let keys = [web, editor, git, terminal].map(\.matchingKey)
        XCTAssertEqual(Set(keys).count, keys.count, "kind sentinels must keep matchingKeys disjoint")
    }
}
