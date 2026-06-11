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

@MainActor
protocol AppCommandApplicationActionPerforming: AnyObject {
    func performNewWindowCommand(_ sender: Any?)
    func performShowCommandPaletteCommand(_ sender: Any?)
    func performCheckForUpdatesCommand(_ sender: Any?)
    func performShowPreferencesCommand(_ sender: Any?)
    func performShowAgentVisualPermissionsCommand(_ sender: Any?)
    func performShowPairedDevicesCommand(_ sender: Any?)
    func performShowConnectedServersCommand(_ sender: Any?)
    func performUninstallSoyehtCommand(_ sender: Any?)
    func performShowClawStoreCommand(_ sender: Any?)
}

@MainActor
protocol AppCommandWindowActionPerforming: AnyObject {
    @discardableResult func performNewConversationCommand(_ sender: Any?) -> Bool
    @discardableResult func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool
    @discardableResult func performUndoWindowActionCommand(_ sender: Any?) -> Bool
    @discardableResult func performRedoWindowActionCommand(_ sender: Any?) -> Bool
    @discardableResult func performSplitPaneVerticalCommand(_ sender: Any?) -> Bool
    @discardableResult func performSplitPaneHorizontalCommand(_ sender: Any?) -> Bool
    @discardableResult func performCloseFocusedPaneCommand(_ sender: Any?) -> Bool
    @discardableResult func performFocusPaneLeftCommand(_ sender: Any?) -> Bool
    @discardableResult func performFocusPaneRightCommand(_ sender: Any?) -> Bool
    @discardableResult func performFocusPaneUpCommand(_ sender: Any?) -> Bool
    @discardableResult func performFocusPaneDownCommand(_ sender: Any?) -> Bool
    @discardableResult func performToggleZoomFocusedPaneCommand(_ sender: Any?) -> Bool
    @discardableResult func performExitZoomCommand(_ sender: Any?) -> Bool
    @discardableResult func performSwapPaneLeftCommand(_ sender: Any?) -> Bool
    @discardableResult func performSwapPaneRightCommand(_ sender: Any?) -> Bool
    @discardableResult func performSwapPaneUpCommand(_ sender: Any?) -> Bool
    @discardableResult func performSwapPaneDownCommand(_ sender: Any?) -> Bool
    @discardableResult func performRotateFocusedSplitCommand(_ sender: Any?) -> Bool
    @discardableResult func performSelectWorkspaceCommand(_ sender: Any?) -> Bool
    @discardableResult func performMoveFocusedPaneToWorkspaceCommand(_ sender: Any?) -> Bool
    @discardableResult func performMoveActiveWorkspaceLeftCommand(_ sender: Any?) -> Bool
    @discardableResult func performMoveActiveWorkspaceRightCommand(_ sender: Any?) -> Bool
}

@MainActor
final class AppCommandActionRouter: AppCommandPerforming {
    weak var applicationActions: AppCommandApplicationActionPerforming?
    weak var windowActions: AppCommandWindowActionPerforming?

    init(
        applicationActions: AppCommandApplicationActionPerforming?,
        windowActions: AppCommandWindowActionPerforming?
    ) {
        self.applicationActions = applicationActions
        self.windowActions = windowActions
    }

    func performAppCommand(_ commandID: AppCommandID, sender: Any?) {
        _ = perform(commandID, sender: sender)
    }

    @discardableResult
    func perform(_ commandID: AppCommandID, sender: Any?) -> Bool {
        switch commandID {
        case .newWindow:
            applicationActions?.performNewWindowCommand(sender)
            return applicationActions != nil
        case .newConversation:
            return windowActions?.performNewConversationCommand(sender) ?? false
        case .showCommandPalette:
            applicationActions?.performShowCommandPaletteCommand(sender)
            return applicationActions != nil
        case .checkForUpdates:
            applicationActions?.performCheckForUpdatesCommand(sender)
            return applicationActions != nil
        case .showPreferences:
            applicationActions?.performShowPreferencesCommand(sender)
            return applicationActions != nil
        case .showAgentVisualPermissions:
            applicationActions?.performShowAgentVisualPermissionsCommand(sender)
            return applicationActions != nil
        case .showPairedDevices:
            applicationActions?.performShowPairedDevicesCommand(sender)
            return applicationActions != nil
        case .showConnectedServers:
            applicationActions?.performShowConnectedServersCommand(sender)
            return applicationActions != nil
        case .uninstallSoyeht:
            applicationActions?.performUninstallSoyehtCommand(sender)
            return applicationActions != nil
        case .showClawStore:
            applicationActions?.performShowClawStoreCommand(sender)
            return applicationActions != nil
        case .showConversationsSidebar:
            return windowActions?.performShowConversationsSidebarCommand(sender) ?? false
        case .undoWindowAction:
            return windowActions?.performUndoWindowActionCommand(sender) ?? false
        case .redoWindowAction:
            return windowActions?.performRedoWindowActionCommand(sender) ?? false
        case .splitPaneVertical:
            return windowActions?.performSplitPaneVerticalCommand(sender) ?? false
        case .splitPaneHorizontal:
            return windowActions?.performSplitPaneHorizontalCommand(sender) ?? false
        case .closeFocusedPane:
            return windowActions?.performCloseFocusedPaneCommand(sender) ?? false
        case .focusPaneLeft:
            return windowActions?.performFocusPaneLeftCommand(sender) ?? false
        case .focusPaneRight:
            return windowActions?.performFocusPaneRightCommand(sender) ?? false
        case .focusPaneUp:
            return windowActions?.performFocusPaneUpCommand(sender) ?? false
        case .focusPaneDown:
            return windowActions?.performFocusPaneDownCommand(sender) ?? false
        case .toggleZoomFocusedPane:
            return windowActions?.performToggleZoomFocusedPaneCommand(sender) ?? false
        case .exitZoom:
            return windowActions?.performExitZoomCommand(sender) ?? false
        case .swapPaneLeft:
            return windowActions?.performSwapPaneLeftCommand(sender) ?? false
        case .swapPaneRight:
            return windowActions?.performSwapPaneRightCommand(sender) ?? false
        case .swapPaneUp:
            return windowActions?.performSwapPaneUpCommand(sender) ?? false
        case .swapPaneDown:
            return windowActions?.performSwapPaneDownCommand(sender) ?? false
        case .rotateFocusedSplit:
            return windowActions?.performRotateFocusedSplitCommand(sender) ?? false
        case .selectWorkspace:
            return windowActions?.performSelectWorkspaceCommand(sender) ?? false
        case .moveFocusedPaneToWorkspace:
            return windowActions?.performMoveFocusedPaneToWorkspaceCommand(sender) ?? false
        case .moveActiveWorkspaceLeft:
            return windowActions?.performMoveActiveWorkspaceLeftCommand(sender) ?? false
        case .moveActiveWorkspaceRight:
            return windowActions?.performMoveActiveWorkspaceRightCommand(sender) ?? false
        }
    }
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
