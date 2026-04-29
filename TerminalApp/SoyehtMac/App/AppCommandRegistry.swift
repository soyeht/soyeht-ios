import Foundation

#if canImport(AppKit)
import AppKit
#endif

enum AppCommandID: Hashable, CustomStringConvertible {
    case newWindow
    case newConversation
    case showCommandPalette
    case showPreferences
    case showPairedDevices
    case showConnectedServers
    case showClawStore
    case showConversationsSidebar
    case undoWindowAction
    case redoWindowAction
    case splitPaneVertical
    case splitPaneHorizontal
    case closeFocusedPane
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case toggleZoomFocusedPane
    case exitZoom
    case swapPaneLeft
    case swapPaneRight
    case swapPaneUp
    case swapPaneDown
    case rotateFocusedSplit
    case selectWorkspace(Int)
    case toggleWorkspaceSelection(Int)
    case moveFocusedPaneToWorkspace(Int)
    case moveActiveWorkspaceLeft
    case moveActiveWorkspaceRight
    case closeSelectedWorkspaces

    var description: String {
        switch self {
        case .newWindow: return "newWindow"
        case .newConversation: return "newConversation"
        case .showCommandPalette: return "showCommandPalette"
        case .showPreferences: return "showPreferences"
        case .showPairedDevices: return "showPairedDevices"
        case .showConnectedServers: return "showConnectedServers"
        case .showClawStore: return "showClawStore"
        case .showConversationsSidebar: return "showConversationsSidebar"
        case .undoWindowAction: return "undoWindowAction"
        case .redoWindowAction: return "redoWindowAction"
        case .splitPaneVertical: return "splitPaneVertical"
        case .splitPaneHorizontal: return "splitPaneHorizontal"
        case .closeFocusedPane: return "closeFocusedPane"
        case .focusPaneLeft: return "focusPaneLeft"
        case .focusPaneRight: return "focusPaneRight"
        case .focusPaneUp: return "focusPaneUp"
        case .focusPaneDown: return "focusPaneDown"
        case .toggleZoomFocusedPane: return "toggleZoomFocusedPane"
        case .exitZoom: return "exitZoom"
        case .swapPaneLeft: return "swapPaneLeft"
        case .swapPaneRight: return "swapPaneRight"
        case .swapPaneUp: return "swapPaneUp"
        case .swapPaneDown: return "swapPaneDown"
        case .rotateFocusedSplit: return "rotateFocusedSplit"
        case .selectWorkspace(let tag): return "selectWorkspace(\(tag))"
        case .toggleWorkspaceSelection(let tag): return "toggleWorkspaceSelection(\(tag))"
        case .moveFocusedPaneToWorkspace(let tag): return "moveFocusedPaneToWorkspace(\(tag))"
        case .moveActiveWorkspaceLeft: return "moveActiveWorkspaceLeft"
        case .moveActiveWorkspaceRight: return "moveActiveWorkspaceRight"
        case .closeSelectedWorkspaces: return "closeSelectedWorkspaces"
        }
    }
}

enum AppCommandAction: String, Hashable {
    case newWindow = "newWindow:"
    case newConversation = "newConversation:"
    case showCommandPalette = "showCommandPalette:"
    case showPreferences = "showPreferences:"
    case showPairedDevices = "showPairedDevices:"
    case showConnectedServers = "showConnectedServers:"
    case showClawStore = "showClawStore:"
    case showConversationsSidebar = "showConversationsSidebar:"
    case undoWindowAction = "undoWindowAction:"
    case redoWindowAction = "redoWindowAction:"
    case splitPaneVertical = "splitPaneVertical:"
    case splitPaneHorizontal = "splitPaneHorizontal:"
    case closeFocusedPane = "closeFocusedPane:"
    case focusPaneLeft = "focusPaneLeft:"
    case focusPaneRight = "focusPaneRight:"
    case focusPaneUp = "focusPaneUp:"
    case focusPaneDown = "focusPaneDown:"
    case toggleZoomFocusedPane = "toggleZoomFocusedPane:"
    case exitZoom = "exitZoom:"
    case swapPaneLeft = "swapPaneLeft:"
    case swapPaneRight = "swapPaneRight:"
    case swapPaneUp = "swapPaneUp:"
    case swapPaneDown = "swapPaneDown:"
    case rotateFocusedSplit = "rotateFocusedSplit:"
    case selectWorkspaceByTag = "selectWorkspaceByTag:"
    case toggleWorkspaceSelectionByTag = "toggleWorkspaceSelectionByTag:"
    case moveFocusedPaneToWorkspaceByTag = "moveFocusedPaneToWorkspaceByTag:"
    case moveActiveWorkspaceLeft = "moveActiveWorkspaceLeft:"
    case moveActiveWorkspaceRight = "moveActiveWorkspaceRight:"
    case closeSelectedWorkspaces = "closeSelectedWorkspaces:"

    var selector: Selector {
        NSSelectorFromString(rawValue)
    }
}

struct AppCommandModifier: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let command = AppCommandModifier(rawValue: 1 << 0)
    static let shift = AppCommandModifier(rawValue: 1 << 1)
    static let option = AppCommandModifier(rawValue: 1 << 2)
    static let control = AppCommandModifier(rawValue: 1 << 3)
}

enum AppCommandSpecialKey: Hashable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case escape

    var virtualKeyCode: UInt16 {
        switch self {
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .downArrow: return 125
        case .upArrow: return 126
        case .escape: return 53
        }
    }

    var menuKeyEquivalent: String {
        switch self {
        case .upArrow: return "\u{F700}"
        case .downArrow: return "\u{F701}"
        case .leftArrow: return "\u{F702}"
        case .rightArrow: return "\u{F703}"
        case .escape: return "\u{1B}"
        }
    }
}

enum AppCommandKey: Hashable {
    case character(String)
    case special(AppCommandSpecialKey)

    var menuKeyEquivalent: String {
        switch normalized {
        case .character(let value): return value
        case .special(let key): return key.menuKeyEquivalent
        }
    }

    func matches(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Bool {
        switch normalized {
        case .character(let expected):
            guard let actual = charactersIgnoringModifiers?.lowercased() else { return false }
            if actual == expected { return true }
            return actual.first.map { String($0) } == expected
        case .special(let key):
            return keyCode == key.virtualKeyCode
        }
    }

    private var normalized: AppCommandKey {
        switch self {
        case .character(let value):
            return .character(value.lowercased())
        case .special:
            return self
        }
    }
}

struct AppCommandShortcut: Hashable, Sendable {
    let key: AppCommandKey
    let modifiers: AppCommandModifier

    init(_ key: AppCommandKey, modifiers: AppCommandModifier) {
        switch key {
        case .character(let value):
            self.key = .character(value.lowercased())
        case .special:
            self.key = key
        }
        self.modifiers = modifiers
    }

    var menuKeyEquivalent: String {
        key.menuKeyEquivalent
    }

    func matches(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers eventModifiers: AppCommandModifier
    ) -> Bool {
        modifiers == eventModifiers
            && key.matches(
                keyCode: keyCode,
                charactersIgnoringModifiers: charactersIgnoringModifiers
            )
    }
}

enum AppCommandContext: String, CaseIterable, Hashable {
    case application
    case shell
    case edit
    case view
    case pane
    case workspace
    case paneGrid
}

enum AppCommandMenuPlacement: Hashable {
    case appMenu
    case shellMenu
    case editMenu
    case viewMenu
    case paneMenu
    case paneMoveToWorkspaceSubmenu
    case workspaceMenu
    case workspaceToggleSelectionSubmenu

    var context: AppCommandContext {
        switch self {
        case .appMenu: return .application
        case .shellMenu: return .shell
        case .editMenu: return .edit
        case .viewMenu: return .view
        case .paneMenu, .paneMoveToWorkspaceSubmenu: return .pane
        case .workspaceMenu, .workspaceToggleSelectionSubmenu: return .workspace
        }
    }
}

struct AppCommand: Hashable {
    let id: AppCommandID
    let title: String
    let action: AppCommandAction
    let shortcut: AppCommandShortcut?
    let menuPlacement: AppCommandMenuPlacement?
    let tag: Int?
    let contexts: Set<AppCommandContext>

    init(
        id: AppCommandID,
        title: String,
        action: AppCommandAction,
        shortcut: AppCommandShortcut?,
        menuPlacement: AppCommandMenuPlacement?,
        tag: Int? = nil,
        localContexts: Set<AppCommandContext> = []
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.shortcut = shortcut
        self.menuPlacement = menuPlacement
        self.tag = tag
        var contexts = localContexts
        if let menuPlacement {
            contexts.insert(menuPlacement.context)
        }
        self.contexts = contexts
    }
}

struct AppCommandShortcutConflict: Hashable {
    let context: AppCommandContext
    let shortcut: AppCommandShortcut
    let commandIDs: [AppCommandID]
}

enum AppCommandMenuTag {
    /// Values are deliberately negative so they never collide with storyboard
    /// positive tags such as workspace slots 1...9.
    static let paneMoveToWorkspaceHeader = -101
    static let workspaceGroupActiveHeader = -102
    static let workspaceToggleSelectionHeader = -103
}

enum AppCommandRegistry {
    static let workspaceTags = 1...9

    static var allCommands: [AppCommand] {
        baseCommands + workspaceTagCommands
    }

    static func command(_ id: AppCommandID) -> AppCommand? {
        allCommands.first { $0.id == id }
    }

    static func commands(in context: AppCommandContext) -> [AppCommand] {
        allCommands.filter { $0.contexts.contains(context) }
    }

    static func commands(in placement: AppCommandMenuPlacement) -> [AppCommand] {
        allCommands.filter { $0.menuPlacement == placement }
    }

    static func command(
        matchingKeyCode keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: AppCommandModifier,
        in context: AppCommandContext
    ) -> AppCommand? {
        commands(in: context).first { command in
            command.shortcut?.matches(
                keyCode: keyCode,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers
            ) == true
        }
    }

    static func duplicateShortcuts() -> [AppCommandShortcutConflict] {
        var buckets: [ShortcutBucket: [AppCommandID]] = [:]
        for command in allCommands {
            guard let shortcut = command.shortcut else { continue }
            for context in command.contexts {
                buckets[ShortcutBucket(context: context, shortcut: shortcut), default: []]
                    .append(command.id)
            }
        }
        return buckets.compactMap { bucket, ids in
            let uniqueIDs = Array(Set(ids)).sorted { $0.description < $1.description }
            guard uniqueIDs.count > 1 else { return nil }
            return AppCommandShortcutConflict(
                context: bucket.context,
                shortcut: bucket.shortcut,
                commandIDs: uniqueIDs
            )
        }
        .sorted {
            if $0.context.rawValue != $1.context.rawValue {
                return $0.context.rawValue < $1.context.rawValue
            }
            return $0.commandIDs.map(\.description).joined(separator: ",")
                < $1.commandIDs.map(\.description).joined(separator: ",")
        }
    }

    private struct ShortcutBucket: Hashable {
        let context: AppCommandContext
        let shortcut: AppCommandShortcut
    }

    private static var baseCommands: [AppCommand] {
        [
            AppCommand(
                id: .newWindow,
                title: "New Window",
                action: .newWindow,
                shortcut: AppCommandShortcut(.character("n"), modifiers: [.command]),
                menuPlacement: .shellMenu
            ),
            AppCommand(
                id: .newConversation,
                title: "New Conversation",
                action: .newConversation,
                shortcut: AppCommandShortcut(.character("t"), modifiers: [.command]),
                menuPlacement: .shellMenu
            ),
            AppCommand(
                id: .showCommandPalette,
                title: String(localized: "appMenu.goToPane", comment: "View menu item that opens the command palette to jump to a workspace or pane."),
                action: .showCommandPalette,
                shortcut: AppCommandShortcut(.character("p"), modifiers: [.command]),
                menuPlacement: .viewMenu
            ),
            AppCommand(
                id: .showPreferences,
                title: "Preferences…",
                action: .showPreferences,
                shortcut: AppCommandShortcut(.character(","), modifiers: [.command]),
                menuPlacement: .appMenu
            ),
            AppCommand(
                id: .showPairedDevices,
                title: String(localized: "appMenu.pairedDevices", comment: "App menu item that opens the Paired Devices window."),
                action: .showPairedDevices,
                shortcut: AppCommandShortcut(.character("d"), modifiers: [.command, .shift]),
                menuPlacement: .appMenu
            ),
            AppCommand(
                id: .showConnectedServers,
                title: String(
                    localized: "appMenu.connectedServers",
                    defaultValue: "Connected Servers…",
                    comment: "App menu item that opens the Connected Servers window."
                ),
                action: .showConnectedServers,
                shortcut: nil,
                menuPlacement: .appMenu
            ),
            AppCommand(
                id: .showClawStore,
                title: String(localized: "appMenu.clawStore", comment: "App menu item that opens the Claw Store window."),
                action: .showClawStore,
                shortcut: AppCommandShortcut(.character("s"), modifiers: [.command, .option]),
                menuPlacement: .appMenu
            ),
            AppCommand(
                id: .showConversationsSidebar,
                title: "Conversations Sidebar",
                action: .showConversationsSidebar,
                shortcut: AppCommandShortcut(.character("c"), modifiers: [.command, .shift]),
                menuPlacement: .workspaceMenu
            ),
            AppCommand(
                id: .undoWindowAction,
                title: "Undo",
                action: .undoWindowAction,
                shortcut: AppCommandShortcut(.character("z"), modifiers: [.command]),
                menuPlacement: .editMenu
            ),
            AppCommand(
                id: .redoWindowAction,
                title: "Redo",
                action: .redoWindowAction,
                shortcut: AppCommandShortcut(.character("y"), modifiers: [.command]),
                menuPlacement: .editMenu
            ),
            AppCommand(
                id: .splitPaneVertical,
                title: "Split Vertical",
                action: .splitPaneVertical,
                shortcut: AppCommandShortcut(.character("|"), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu
            ),
            AppCommand(
                id: .splitPaneHorizontal,
                title: "Split Horizontal",
                action: .splitPaneHorizontal,
                shortcut: AppCommandShortcut(.character("_"), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu
            ),
            AppCommand(
                id: .closeFocusedPane,
                title: "Close Pane",
                action: .closeFocusedPane,
                shortcut: nil,
                menuPlacement: .paneMenu
            ),
            AppCommand(
                id: .focusPaneLeft,
                title: "Focus Left",
                action: .focusPaneLeft,
                shortcut: AppCommandShortcut(.special(.leftArrow), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .focusPaneRight,
                title: "Focus Right",
                action: .focusPaneRight,
                shortcut: AppCommandShortcut(.special(.rightArrow), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .focusPaneUp,
                title: "Focus Up",
                action: .focusPaneUp,
                shortcut: AppCommandShortcut(.special(.upArrow), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .focusPaneDown,
                title: "Focus Down",
                action: .focusPaneDown,
                shortcut: AppCommandShortcut(.special(.downArrow), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .toggleZoomFocusedPane,
                title: String(localized: "paneMenu.zoomFocused", comment: "Pane menu item — zoom the focused pane to fill the window."),
                action: .toggleZoomFocusedPane,
                shortcut: AppCommandShortcut(.character("z"), modifiers: [.command, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .exitZoom,
                title: String(localized: "paneMenu.exitZoom", comment: "Pane menu item — exits zoom mode."),
                action: .exitZoom,
                shortcut: AppCommandShortcut(.special(.escape), modifiers: []),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .swapPaneLeft,
                title: String(localized: "paneMenu.swapLeft", comment: "Pane menu item — swap the focused pane with the one to its left."),
                action: .swapPaneLeft,
                shortcut: AppCommandShortcut(.special(.leftArrow), modifiers: [.option, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .swapPaneRight,
                title: String(localized: "paneMenu.swapRight", comment: "Pane menu item — swap the focused pane with the one to its right."),
                action: .swapPaneRight,
                shortcut: AppCommandShortcut(.special(.rightArrow), modifiers: [.option, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .swapPaneUp,
                title: String(localized: "paneMenu.swapUp", comment: "Pane menu item — swap the focused pane with the one above."),
                action: .swapPaneUp,
                shortcut: AppCommandShortcut(.special(.upArrow), modifiers: [.option, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .swapPaneDown,
                title: String(localized: "paneMenu.swapDown", comment: "Pane menu item — swap the focused pane with the one below."),
                action: .swapPaneDown,
                shortcut: AppCommandShortcut(.special(.downArrow), modifiers: [.option, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .rotateFocusedSplit,
                title: String(localized: "paneMenu.rotateSplit", comment: "Pane menu item — rotate the axis of the split containing the focused pane."),
                action: .rotateFocusedSplit,
                shortcut: AppCommandShortcut(.character("r"), modifiers: [.option, .shift]),
                menuPlacement: .paneMenu,
                localContexts: [.paneGrid]
            ),
            AppCommand(
                id: .moveActiveWorkspaceLeft,
                title: String(localized: "workspaceMenu.moveActiveLeft", comment: "Workspace menu item — move the active workspace one slot to the left."),
                action: .moveActiveWorkspaceLeft,
                shortcut: AppCommandShortcut(.character("["), modifiers: [.command, .control]),
                menuPlacement: .workspaceMenu
            ),
            AppCommand(
                id: .moveActiveWorkspaceRight,
                title: String(localized: "workspaceMenu.moveActiveRight", comment: "Workspace menu item — move the active workspace one slot to the right."),
                action: .moveActiveWorkspaceRight,
                shortcut: AppCommandShortcut(.character("]"), modifiers: [.command, .control]),
                menuPlacement: .workspaceMenu
            ),
            AppCommand(
                id: .closeSelectedWorkspaces,
                title: String(localized: "workspaceMenu.closeSelected", comment: "Workspace menu item — bulk-close currently multi-selected workspaces."),
                action: .closeSelectedWorkspaces,
                shortcut: nil,
                menuPlacement: .workspaceMenu
            ),
        ]
    }

    private static var workspaceTagCommands: [AppCommand] {
        workspaceTags.flatMap { tag in
            [
                AppCommand(
                    id: .selectWorkspace(tag),
                    title: String(
                        localized: "workspaceMenu.byTag",
                        defaultValue: "Workspace \(tag)",
                        comment: "Workspace menu item — activates workspace at the given tag. %lld = workspace tag."
                    ),
                    action: .selectWorkspaceByTag,
                    shortcut: AppCommandShortcut(.character("\(tag)"), modifiers: [.command]),
                    menuPlacement: .workspaceMenu,
                    tag: tag
                ),
                AppCommand(
                    id: .toggleWorkspaceSelection(tag),
                    title: String(
                        localized: "workspaceMenu.toggleSelection.workspace",
                        defaultValue: "Workspace \(tag)",
                        comment: "Toggle-selection submenu item. %lld = workspace tag."
                    ),
                    action: .toggleWorkspaceSelectionByTag,
                    shortcut: AppCommandShortcut(.character("\(tag)"), modifiers: [.command, .option]),
                    menuPlacement: .workspaceToggleSelectionSubmenu,
                    tag: tag
                ),
                AppCommand(
                    id: .moveFocusedPaneToWorkspace(tag),
                    title: String(
                        localized: "paneMenu.moveTo.workspace",
                        defaultValue: "Workspace \(tag)",
                        comment: "Submenu item — destination workspace. %lld = workspace tag (1-9)."
                    ),
                    action: .moveFocusedPaneToWorkspaceByTag,
                    shortcut: AppCommandShortcut(.character("\(tag)"), modifiers: [.control, .option]),
                    menuPlacement: .paneMoveToWorkspaceSubmenu,
                    tag: tag
                ),
            ]
        }
    }
}

#if canImport(AppKit)
extension AppCommandModifier {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: AppCommandModifier = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension AppCommandRegistry {
    static func command(matching event: NSEvent, in context: AppCommandContext) -> AppCommand? {
        command(
            matchingKeyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: AppCommandModifier(event.modifierFlags),
            in: context
        )
    }
}
#endif
