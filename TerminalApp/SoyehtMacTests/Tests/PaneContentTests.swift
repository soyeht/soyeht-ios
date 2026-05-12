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
}
