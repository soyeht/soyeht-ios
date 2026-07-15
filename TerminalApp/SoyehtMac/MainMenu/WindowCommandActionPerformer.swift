import AppKit

@MainActor
final class UICommandWindowActionPerformer: AppCommandWindowActionPerforming {
    private let targetProvider: () -> SoyehtMainWindowController?

    init(targetProvider: @escaping () -> SoyehtMainWindowController?) {
        self.targetProvider = targetProvider
    }

    @discardableResult
    func performNewConversationCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.newConversation(sender)
        return true
    }

    @discardableResult
    func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.toggleSidebarOverlay()
        return true
    }

    @discardableResult
    func performUndoWindowActionCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.window?.undoManager?.undo()
        target.refreshWorkspaceChromeFromStore()
        return true
    }

    @discardableResult
    func performRedoWindowActionCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.window?.undoManager?.redo()
        target.refreshWorkspaceChromeFromStore()
        return true
    }

    @discardableResult
    func performSplitPaneVerticalCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.splitPaneVertical(sender) }
    }

    @discardableResult
    func performSplitPaneHorizontalCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.splitPaneHorizontal(sender) }
    }

    @discardableResult
    func performCloseFocusedPaneCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.closeFocusedPane(sender) }
    }

    @discardableResult
    func performFocusPaneLeftCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneLeft(sender) }
    }

    @discardableResult
    func performFocusPaneRightCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneRight(sender) }
    }

    @discardableResult
    func performFocusPaneUpCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneUp(sender) }
    }

    @discardableResult
    func performFocusPaneDownCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.focusPaneDown(sender) }
    }

    @discardableResult
    func performToggleZoomFocusedPaneCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.toggleZoomFocusedPane(sender) }
    }

    @discardableResult
    func performExitZoomCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.exitZoom(sender) }
    }

    @discardableResult
    func performSwapPaneLeftCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneLeft(sender) }
    }

    @discardableResult
    func performSwapPaneRightCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneRight(sender) }
    }

    @discardableResult
    func performSwapPaneUpCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneUp(sender) }
    }

    @discardableResult
    func performSwapPaneDownCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.swapPaneDown(sender) }
    }

    @discardableResult
    func performRotateFocusedSplitCommand(_ sender: Any?) -> Bool {
        withActivePaneGrid { $0.rotateFocusedSplit(sender) }
    }

    @discardableResult
    func performSelectWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.selectWorkspaceByTag(sender)
        return true
    }

    @discardableResult
    func performMoveFocusedPaneToWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveFocusedPaneToWorkspaceByTag(sender)
        return true
    }

    @discardableResult
    func performMoveActiveWorkspaceLeftCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveActiveWorkspaceLeft(sender)
        return true
    }

    @discardableResult
    func performMoveActiveWorkspaceRightCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else { return false }
        target.moveActiveWorkspaceRight(sender)
        return true
    }

    @discardableResult
    func performNewGroupForActiveWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.promptCreateGroupForActiveWorkspace(sender)
        return true
    }

    @discardableResult
    func performAssignActiveWorkspaceToGroupCommand(_ sender: NSMenuItem) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.assignActiveWorkspaceToGroup(sender.representedObject as? Group.ID)
        return true
    }

    @discardableResult
    func performCloseActiveWorkspaceCommand(_ sender: Any?) -> Bool {
        guard let target = targetProvider() else {
            NSSound.beep()
            return false
        }
        target.closeActiveWorkspace(sender)
        return true
    }

    @discardableResult
    private func withActivePaneGrid(_ body: (PaneGridController) -> Void) -> Bool {
        guard let grid = targetProvider()?.activeGridController else {
            NSSound.beep()
            return false
        }
        body(grid)
        return true
    }
}
