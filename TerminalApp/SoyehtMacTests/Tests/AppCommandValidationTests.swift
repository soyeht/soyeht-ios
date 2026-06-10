import XCTest
@testable import SoyehtMacDomain

final class AppCommandValidationTests: XCTestCase {
    func testNewConversationRequiresFrontmostWindow() throws {
        let command = try command(.newConversation)

        XCTAssertFalse(command.isEnabled(in: CommandUIContext()))
        XCTAssertTrue(command.isEnabled(in: CommandUIContext(frontmostWindow: MainWindowCommandUIState())))
    }

    func testCloseWorkspaceRequiresMultipleWorkspaces() {
        XCTAssertFalse(
            MainMenuExplicitRole.closeWorkspace.isEnabled(
                in: CommandUIContext(frontmostWindow: MainWindowCommandUIState(workspaceCount: 1))
            )
        )
        XCTAssertTrue(
            MainMenuExplicitRole.closeWorkspace.isEnabled(
                in: CommandUIContext(frontmostWindow: MainWindowCommandUIState(workspaceCount: 2))
            )
        )
    }

    func testPaneFocusAndSwapUsePaneGridState() throws {
        let window = MainWindowCommandUIState(
            paneGrid: PaneCommandUIState(
                canActOnFocusedPane: true,
                focusableDirections: [.left],
                swappableDirections: [.right]
            )
        )
        let context = CommandUIContext(frontmostWindow: window)

        XCTAssertTrue(try command(.focusPaneLeft).isEnabled(in: context))
        XCTAssertFalse(try command(.focusPaneRight).isEnabled(in: context))
        XCTAssertTrue(try command(.swapPaneRight).isEnabled(in: context))
        XCTAssertFalse(try command(.swapPaneLeft).isEnabled(in: context))
        XCTAssertTrue(try command(.splitPaneVertical).isEnabled(in: context))
    }

    func testUndoRedoValidationUpdatesTitleAndEnabledState() throws {
        let undo = try command(.undoWindowAction)
        let redo = try command(.redoWindowAction)
        let empty = CommandUIContext(undo: UndoCommandUIState())

        XCTAssertFalse(undo.isEnabled(in: empty))
        XCTAssertEqual(undo.validation(in: empty).title, undo.title)
        XCTAssertFalse(redo.isEnabled(in: empty))
        XCTAssertEqual(redo.validation(in: empty).title, redo.title)

        let context = CommandUIContext(undo: UndoCommandUIState(
            canUndo: true,
            canRedo: true,
            undoMenuItemTitle: "Undo Rename",
            redoMenuItemTitle: "Redo Rename"
        ))
        XCTAssertTrue(undo.isEnabled(in: context))
        XCTAssertEqual(undo.validation(in: context).title, "Undo Rename")
        XCTAssertTrue(redo.isEnabled(in: context))
        XCTAssertEqual(redo.validation(in: context).title, "Redo Rename")
    }

    func testClawStoreFollowsFeatureFlag() throws {
        let command = try command(.showClawStore)

        XCTAssertFalse(command.isEnabled(in: CommandUIContext(clawStoreEnabled: false)))
        XCTAssertTrue(command.isEnabled(in: CommandUIContext(clawStoreEnabled: true)))
    }

    func testCheckForUpdatesFollowsUpdaterState() throws {
        let command = try command(.checkForUpdates)

        XCTAssertFalse(command.isEnabled(in: CommandUIContext(canCheckForUpdates: false)))
        XCTAssertTrue(command.isEnabled(in: CommandUIContext(canCheckForUpdates: true)))
    }

    private func command(_ id: AppCommandID) throws -> AppCommand {
        try XCTUnwrap(AppCommandRegistry.command(id), "Missing command \(id)")
    }
}

private extension MainMenuExplicitRole {
    func isEnabled(in context: CommandUIContext) -> Bool {
        validation(in: context).isEnabled
    }
}
