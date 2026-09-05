import XCTest
@testable import SoyehtMacDomain

/// A terminal pane used to persist nothing about its folder: `.terminal`
/// content is an empty struct and `startLocalShell` created the conversation
/// without a `workingDirectoryPath`. MEASURED on 2026-09-04, after a
/// WindowServer crash logged the macOS session out: 45 of 52 stored
/// conversations had no path, and every one of them came back as a shell in
/// `~` instead of the project it was opened in. Editor/git/web/app panes each
/// persisted their own path and restored correctly; terminal was the one kind
/// that did not.
@MainActor
final class TerminalPaneWorkingDirectoryTests: XCTestCase {

    private func makeShellPane(ws: Workspace.ID, path: String?) -> Conversation {
        Conversation(
            handle: "shellpane",
            agent: .shell,
            workspaceID: ws,
            commander: .placeholderMirror,
            workingDirectoryPath: path
        )
    }

    func testWorkingDirectorySurvivesAnEncodeDecodeRound() throws {
        let conversation = makeShellPane(ws: UUID(), path: "/Users/someone/Documents/project")
        let data = try JSONEncoder().encode(conversation)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(restored.workingDirectoryPath, "/Users/someone/Documents/project")
    }

    func testStoreRecordsTheFolderAPaneIsSittingIn() throws {
        let store = ConversationStore()
        let stored = store.add(makeShellPane(ws: UUID(), path: nil))
        XCTAssertNil(stored.workingDirectoryPath)

        store.updateWorkingDirectory(stored.id, path: "/Users/someone/Documents/job-hunter")
        XCTAssertEqual(
            store.conversation(stored.id)?.workingDirectoryPath,
            "/Users/someone/Documents/job-hunter"
        )
    }

    func testLaterDirectoryChangeOverwritesTheLaunchFolder() throws {
        let store = ConversationStore()
        let stored = store.add(makeShellPane(ws: UUID(), path: "/Users/someone"))
        store.updateWorkingDirectory(stored.id, path: "/Users/someone/Documents")
        XCTAssertEqual(
            store.conversation(stored.id)?.workingDirectoryPath,
            "/Users/someone/Documents"
        )
    }

    /// Guards the two ends the store cannot see: the shell pane is created
    /// WITH its cwd, and a restore prefers that folder over the workspace
    /// default — but only while the folder still exists, because the engine
    /// cannot spawn a shell in a deleted directory.
    func testShellPaneCreationPersistsItsLaunchDirectory() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        XCTAssertTrue(source.contains("convStore.updateWorkingDirectory(paneID, path: cwd.path)"))
    }

    func testRestorePrefersThePanesOwnFolderWhenItStillExists() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        XCTAssertTrue(source.contains("private func restoreDirectory(for conv: Conversation) -> URL"))
        XCTAssertTrue(source.contains("let url = restoreDirectory(for: conv)"))
        XCTAssertTrue(source.contains("FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)"))
        // No caller may go back to reading the field without the guard.
        XCTAssertFalse(source.contains("conv.workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }"))
    }

    func testOSC7KeepsThePersistedFolderCurrent() throws {
        let view = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(view.contains("func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {"))
        XCTAssertTrue(view.contains("onHostDirectoryChanged?(path)"))
        let pane = try macSource("PaneGrid/PaneViewController.swift")
        XCTAssertTrue(pane.contains("terminalView.onHostDirectoryChanged = { [weak self] path in"))
        XCTAssertTrue(pane.contains("updateWorkingDirectory("))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
