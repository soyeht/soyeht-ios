import Foundation

#if canImport(AppKit)
import AppKit
#endif

enum CommandUIDirection: Hashable {
    case left
    case right
    case up
    case down
}

struct PaneCommandUIState: Hashable {
    var canActOnFocusedPane: Bool
    var hasZoomedPane: Bool
    var canRotateFocusedSplit: Bool
    var focusableDirections: Set<CommandUIDirection>
    var swappableDirections: Set<CommandUIDirection>

    init(
        canActOnFocusedPane: Bool = false,
        hasZoomedPane: Bool = false,
        canRotateFocusedSplit: Bool = false,
        focusableDirections: Set<CommandUIDirection> = [],
        swappableDirections: Set<CommandUIDirection> = []
    ) {
        self.canActOnFocusedPane = canActOnFocusedPane
        self.hasZoomedPane = hasZoomedPane
        self.canRotateFocusedSplit = canRotateFocusedSplit
        self.focusableDirections = focusableDirections
        self.swappableDirections = swappableDirections
    }

    func canFocus(_ direction: CommandUIDirection) -> Bool {
        focusableDirections.contains(direction)
    }

    func canSwap(_ direction: CommandUIDirection) -> Bool {
        swappableDirections.contains(direction)
    }
}

struct MainWindowCommandUIState: Hashable {
    var workspaceCount: Int
    var activeWorkspaceTag: Int?
    var selectableWorkspaceTags: Set<Int>
    var moveFocusedPaneDestinationTags: Set<Int>
    var canMoveActiveWorkspaceLeft: Bool
    var canMoveActiveWorkspaceRight: Bool
    var paneGrid: PaneCommandUIState?

    init(
        workspaceCount: Int = 0,
        activeWorkspaceTag: Int? = nil,
        selectableWorkspaceTags: Set<Int> = [],
        moveFocusedPaneDestinationTags: Set<Int> = [],
        canMoveActiveWorkspaceLeft: Bool = false,
        canMoveActiveWorkspaceRight: Bool = false,
        paneGrid: PaneCommandUIState? = nil
    ) {
        self.workspaceCount = workspaceCount
        self.activeWorkspaceTag = activeWorkspaceTag
        self.selectableWorkspaceTags = selectableWorkspaceTags
        self.moveFocusedPaneDestinationTags = moveFocusedPaneDestinationTags
        self.canMoveActiveWorkspaceLeft = canMoveActiveWorkspaceLeft
        self.canMoveActiveWorkspaceRight = canMoveActiveWorkspaceRight
        self.paneGrid = paneGrid
    }
}

struct UndoCommandUIState: Hashable {
    var canUndo: Bool
    var canRedo: Bool
    var undoMenuItemTitle: String?
    var redoMenuItemTitle: String?

    init(
        canUndo: Bool = false,
        canRedo: Bool = false,
        undoMenuItemTitle: String? = nil,
        redoMenuItemTitle: String? = nil
    ) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoMenuItemTitle = undoMenuItemTitle
        self.redoMenuItemTitle = redoMenuItemTitle
    }
}

struct CommandUIContext: Hashable {
    var frontmostWindow: MainWindowCommandUIState?
    var activeWindow: MainWindowCommandUIState?
    var undo: UndoCommandUIState
    var hasPairedServers: Bool
    var clawStoreEnabled: Bool
    var canCheckForUpdates: Bool
    var terminalFontSize: Double
    var defaultTerminalFontSize: Double
    var minimumTerminalFontSize: Double

    init(
        frontmostWindow: MainWindowCommandUIState? = nil,
        activeWindow: MainWindowCommandUIState? = nil,
        undo: UndoCommandUIState = UndoCommandUIState(),
        hasPairedServers: Bool = false,
        clawStoreEnabled: Bool = false,
        canCheckForUpdates: Bool = true,
        terminalFontSize: Double = 13,
        defaultTerminalFontSize: Double = 13,
        minimumTerminalFontSize: Double = 8
    ) {
        self.frontmostWindow = frontmostWindow
        self.activeWindow = activeWindow
        self.undo = undo
        self.hasPairedServers = hasPairedServers
        self.clawStoreEnabled = clawStoreEnabled
        self.canCheckForUpdates = canCheckForUpdates
        self.terminalFontSize = terminalFontSize
        self.defaultTerminalFontSize = defaultTerminalFontSize
        self.minimumTerminalFontSize = minimumTerminalFontSize
    }
}

struct MainWindowCommandTargetResolver<Target> {
    var keyWindowTarget: Target?
    var mainWindowTarget: Target?
    var automationFallbackTarget: Target?

    init(
        keyWindowTarget: Target? = nil,
        mainWindowTarget: Target? = nil,
        automationFallbackTarget: Target? = nil
    ) {
        self.keyWindowTarget = keyWindowTarget
        self.mainWindowTarget = mainWindowTarget
        self.automationFallbackTarget = automationFallbackTarget
    }

    var uiTarget: Target? {
        keyWindowTarget ?? mainWindowTarget
    }

    var automationTarget: Target? {
        uiTarget ?? automationFallbackTarget
    }
}

struct CommandUIValidation: Hashable {
    var isEnabled: Bool
    var title: String?
    var state: MenuItemState?

    init(isEnabled: Bool, title: String? = nil, state: MenuItemState? = nil) {
        self.isEnabled = isEnabled
        self.title = title
        self.state = state
    }

    static func enabled(title: String? = nil, state: MenuItemState? = nil) -> CommandUIValidation {
        CommandUIValidation(isEnabled: true, title: title, state: state)
    }

    static func disabled(title: String? = nil, state: MenuItemState? = nil) -> CommandUIValidation {
        CommandUIValidation(isEnabled: false, title: title, state: state)
    }
}

extension AppCommand {
    func isEnabled(in context: CommandUIContext) -> Bool {
        validation(in: context).isEnabled
    }

    func validation(in context: CommandUIContext) -> CommandUIValidation {
        switch id {
        case .newWindow,
             .showCommandPalette,
             .showPreferences,
             .showAgentVisualPermissions,
             .showPairedDevices,
             .showConnectedServers,
             .uninstallSoyeht:
            return .enabled()
        case .newConversation:
            return CommandUIValidation(isEnabled: context.frontmostWindow != nil)
        case .checkForUpdates:
            return CommandUIValidation(isEnabled: context.canCheckForUpdates)
        case .showClawStore:
            return CommandUIValidation(isEnabled: context.clawStoreEnabled)
        case .showConversationsSidebar:
            return CommandUIValidation(isEnabled: context.frontmostWindow != nil)
        case .undoWindowAction:
            let fallback = String(
                localized: "editMenu.undo.default",
                defaultValue: "Undo",
                comment: "Default Edit > Undo title when no undo is available."
            )
            return CommandUIValidation(
                isEnabled: context.undo.canUndo,
                title: menuTitle(context.undo.undoMenuItemTitle, fallback: fallback)
            )
        case .redoWindowAction:
            let fallback = String(
                localized: "editMenu.redo.default",
                defaultValue: "Redo",
                comment: "Default Edit > Redo title when no redo is available."
            )
            return CommandUIValidation(
                isEnabled: context.undo.canRedo,
                title: menuTitle(context.undo.redoMenuItemTitle, fallback: fallback)
            )
        case .splitPaneVertical, .splitPaneHorizontal, .toggleZoomFocusedPane:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canActOnFocusedPane == true
            )
        case .closeFocusedPane:
            return CommandUIValidation(isEnabled: context.frontmostWindow?.paneGrid != nil)
        case .focusPaneLeft:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canFocus(.left) == true
            )
        case .focusPaneRight:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canFocus(.right) == true
            )
        case .focusPaneUp:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canFocus(.up) == true
            )
        case .focusPaneDown:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canFocus(.down) == true
            )
        case .exitZoom:
            return CommandUIValidation(isEnabled: context.frontmostWindow?.paneGrid?.hasZoomedPane == true)
        case .swapPaneLeft:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canSwap(.left) == true
            )
        case .swapPaneRight:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canSwap(.right) == true
            )
        case .swapPaneUp:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canSwap(.up) == true
            )
        case .swapPaneDown:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canSwap(.down) == true
            )
        case .rotateFocusedSplit:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.paneGrid?.canRotateFocusedSplit == true
            )
        case .selectWorkspace(let tag):
            return CommandUIValidation(
                isEnabled: context.activeWindow?.selectableWorkspaceTags.contains(tag) == true,
                state: context.activeWindow?.activeWorkspaceTag == tag ? .on : .off
            )
        case .moveFocusedPaneToWorkspace(let tag):
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.moveFocusedPaneDestinationTags.contains(tag) == true
            )
        case .moveActiveWorkspaceLeft:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.canMoveActiveWorkspaceLeft == true
            )
        case .moveActiveWorkspaceRight:
            return CommandUIValidation(
                isEnabled: context.frontmostWindow?.canMoveActiveWorkspaceRight == true
            )
        }
    }

    private func menuTitle(_ title: String?, fallback: String) -> String {
        guard let title, !title.isEmpty else { return fallback }
        return title
    }
}

extension MainMenuExplicitRole {
    func validation(in context: CommandUIContext) -> CommandUIValidation {
        switch self {
        case .closeWorkspace:
            return CommandUIValidation(isEnabled: (context.frontmostWindow?.workspaceCount ?? 0) > 1)
        case .logout:
            return CommandUIValidation(isEnabled: context.hasPairedServers)
        case .actualSize:
            return CommandUIValidation(isEnabled: context.terminalFontSize != context.defaultTerminalFontSize)
        case .zoomIn:
            return .enabled()
        case .zoomOut:
            return CommandUIValidation(isEnabled: context.terminalFontSize > context.minimumTerminalFontSize)
        case .assignActiveWorkspaceToNoGroup, .newGroupForActiveWorkspace:
            return CommandUIValidation(isEnabled: context.activeWindow != nil)
        }
    }
}

@MainActor
protocol AppCommandPerforming: AnyObject {
    func performAppCommand(_ commandID: AppCommandID, sender: Any?)
}

struct CommandDispatcher {
    static let action = NSSelectorFromString("dispatchAppCommand:")

    weak var performer: AppCommandPerforming?

    @discardableResult
    @MainActor
    func dispatch(_ sender: Any?) -> Bool {
        guard let commandID = Self.commandID(from: sender) else { return false }
        performer?.performAppCommand(commandID, sender: sender)
        return performer != nil
    }

    static func commandID(from sender: Any?) -> AppCommandID? {
        if let commandID = sender as? AppCommandID {
            return commandID
        }
        #if canImport(AppKit)
        return (sender as? NSMenuItem)?.representedObject as? AppCommandID
        #else
        return nil
        #endif
    }
}
