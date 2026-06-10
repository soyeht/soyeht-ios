import Foundation

enum MainMenuID: String, Hashable {
    case main
    case app
    case shell
    case edit
    case find
    case speech
    case view
    case pane
    case movePaneToWorkspace
    case workspaces
    case groupActiveWorkspace
    case sound
    case dictationLanguage
    case window
    case help
}

enum MainMenuDynamicSectionID: String, Hashable {
    case movePaneToWorkspace
    case workspaces
    case dictationLanguage
}

enum MainMenuTag {
    static let soundTopLevel = -701
    static let soundDictationLanguage = -702
    static let workspaceUnavailable = -801
    static let paneMoveUnavailable = -802
}

struct MenuModel: Hashable {
    let title: String
    let topLevelMenus: [TopLevelMenuModel]
}

struct TopLevelMenuModel: Hashable {
    let id: MainMenuID
    let title: String
    let tag: Int?
    let items: [MenuItemModel]

    init(
        id: MainMenuID,
        title: String,
        tag: Int? = nil,
        items: [MenuItemModel]
    ) {
        self.id = id
        self.title = title
        self.tag = tag
        self.items = items
    }
}

enum MenuItemModel: Hashable {
    case command(AppCommandID)
    case system(MainMenuSystemRole)
    case explicit(MainMenuExplicitRole)
    case disabled(title: String, tag: Int? = nil)
    case submenu(id: MainMenuID, title: String, tag: Int? = nil, items: [MenuItemModel])
    case dynamic(MainMenuDynamicSectionID)
    case separator
}

enum MenuItemState: Hashable {
    case off
    case on
    case mixed
}

enum MainMenuSystemRole: Hashable {
    case aboutSoyeht
    case hideSoyeht
    case hideOthers
    case showAll
    case quitSoyeht
    case closeWindow
    case cut
    case copy
    case paste
    case pasteAndMatchStyle
    case delete
    case selectAll
    case useOptionAsMetaKey
    case find
    case findAndReplace
    case findNext
    case findPrevious
    case useSelectionForFind
    case jumpToSelection
    case startSpeaking
    case stopSpeaking
    case enterFullScreen
    case minimize
    case zoom
    case bringAllToFront
    case soyehtHelp

    var title: String {
        switch self {
        case .aboutSoyeht: return "About Soyeht"
        case .hideSoyeht: return "Hide Soyeht"
        case .hideOthers: return "Hide Others"
        case .showAll: return "Show All"
        case .quitSoyeht: return "Quit Soyeht"
        case .closeWindow: return "Close"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .pasteAndMatchStyle: return "Paste and Match Style"
        case .delete: return "Delete"
        case .selectAll: return "Select All"
        case .useOptionAsMetaKey: return "Use Option as Meta Key"
        case .find: return "Find" + Self.ellipsis
        case .findAndReplace: return "Find and Replace" + Self.ellipsis
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .useSelectionForFind: return "Use Selection for Find"
        case .jumpToSelection: return "Jump to Selection"
        case .startSpeaking: return "Start Speaking"
        case .stopSpeaking: return "Stop Speaking"
        case .enterFullScreen: return "Enter Full Screen"
        case .minimize: return "Minimize"
        case .zoom: return "Zoom"
        case .bringAllToFront: return "Bring All to Front"
        case .soyehtHelp: return "Soyeht Help"
        }
    }

    var action: String {
        switch self {
        case .aboutSoyeht: return "orderFrontStandardAboutPanel:"
        case .hideSoyeht: return "hide:"
        case .hideOthers: return "hideOtherApplications:"
        case .showAll: return "unhideAllApplications:"
        case .quitSoyeht: return "terminate:"
        case .closeWindow: return "performClose:"
        case .cut: return "cut:"
        case .copy: return "copy:"
        case .paste: return "paste:"
        case .pasteAndMatchStyle: return "pasteAsPlainText:"
        case .delete: return "delete:"
        case .selectAll: return "selectAll:"
        case .useOptionAsMetaKey: return "toggleOptionAsMetaKey:"
        case .find, .findAndReplace, .findNext, .findPrevious, .useSelectionForFind:
            return "performFindPanelAction:"
        case .jumpToSelection: return "centerSelectionInVisibleArea:"
        case .startSpeaking: return "startSpeaking:"
        case .stopSpeaking: return "stopSpeaking:"
        case .enterFullScreen: return "toggleFullScreen:"
        case .minimize: return "performMiniaturize:"
        case .zoom: return "performZoom:"
        case .bringAllToFront: return "arrangeInFront:"
        case .soyehtHelp: return "showHelp:"
        }
    }

    var shortcut: AppCommandShortcut? {
        switch self {
        case .hideSoyeht:
            return AppCommandShortcut(.character("h"), modifiers: [.command])
        case .hideOthers:
            return AppCommandShortcut(.character("h"), modifiers: [.command, .option])
        case .quitSoyeht:
            return AppCommandShortcut(.character("q"), modifiers: [.command])
        case .closeWindow:
            return AppCommandShortcut(.character("w"), modifiers: [.command])
        case .cut:
            return AppCommandShortcut(.character("x"), modifiers: [.command])
        case .copy:
            return AppCommandShortcut(.character("c"), modifiers: [.command])
        case .paste:
            return AppCommandShortcut(.character("v"), modifiers: [.command])
        case .pasteAndMatchStyle:
            return AppCommandShortcut(.character("v"), modifiers: [.command, .option])
        case .selectAll:
            return AppCommandShortcut(.character("a"), modifiers: [.command])
        case .useOptionAsMetaKey:
            return AppCommandShortcut(.character("o"), modifiers: [.command, .option])
        case .find:
            return AppCommandShortcut(.character("f"), modifiers: [.command])
        case .findAndReplace:
            return AppCommandShortcut(.character("f"), modifiers: [.command, .option])
        case .findNext:
            return AppCommandShortcut(.character("g"), modifiers: [.command])
        case .findPrevious:
            return AppCommandShortcut(.character("g"), modifiers: [.command, .shift])
        case .useSelectionForFind:
            return AppCommandShortcut(.character("e"), modifiers: [.command])
        case .jumpToSelection:
            return AppCommandShortcut(.character("j"), modifiers: [.command])
        case .enterFullScreen:
            return AppCommandShortcut(.character("f"), modifiers: [.command, .control])
        case .minimize:
            return AppCommandShortcut(.character("m"), modifiers: [.command])
        case .soyehtHelp:
            return AppCommandShortcut(.character("?"), modifiers: [.command])
        case .aboutSoyeht, .showAll, .delete, .startSpeaking, .stopSpeaking, .zoom, .bringAllToFront:
            return nil
        }
    }

    var tag: Int? {
        switch self {
        case .find: return 1
        case .findAndReplace: return 12
        case .findNext: return 2
        case .findPrevious: return 3
        case .useSelectionForFind: return 7
        default: return nil
        }
    }

    var state: MenuItemState {
        switch self {
        case .useOptionAsMetaKey: return .on
        default: return .off
        }
    }

    private static let ellipsis = "\u{2026}"
}

enum MainMenuExplicitRole: Hashable {
    case closeWorkspace
    case logout
    case actualSize
    case zoomIn
    case zoomOut
    case assignActiveWorkspaceToNoGroup
    case newGroupForActiveWorkspace

    var title: String {
        switch self {
        case .closeWorkspace: return "Close Workspace"
        case .logout: return "Logout" + Self.ellipsis
        case .actualSize: return "Actual Size"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .assignActiveWorkspaceToNoGroup: return "None"
        case .newGroupForActiveWorkspace: return "New Group" + Self.ellipsis
        }
    }

    var action: String {
        switch self {
        case .closeWorkspace: return "closeActiveWorkspace:"
        case .logout: return "logout:"
        case .actualSize: return "defaultFontSize:"
        case .zoomIn: return "biggerFont:"
        case .zoomOut: return "smallerFont:"
        case .assignActiveWorkspaceToNoGroup: return "assignActiveWorkspaceToGroup:"
        case .newGroupForActiveWorkspace: return "newGroupForActiveWorkspace:"
        }
    }

    var shortcut: AppCommandShortcut? {
        switch self {
        case .closeWorkspace:
            return AppCommandShortcut(.character("w"), modifiers: [.command, .shift])
        case .actualSize:
            return AppCommandShortcut(.character("0"), modifiers: [.command])
        case .zoomIn:
            return AppCommandShortcut(.character("+"), modifiers: [.command])
        case .zoomOut:
            return AppCommandShortcut(.character("-"), modifiers: [.command])
        case .logout, .assignActiveWorkspaceToNoGroup, .newGroupForActiveWorkspace:
            return nil
        }
    }

    var state: MenuItemState {
        switch self {
        case .assignActiveWorkspaceToNoGroup: return .on
        default: return .off
        }
    }

    var isEnabled: Bool {
        switch self {
        case .assignActiveWorkspaceToNoGroup, .newGroupForActiveWorkspace:
            return false
        default:
            return true
        }
    }

    private static let ellipsis = "\u{2026}"
}

extension MenuModel {
    static func publicNoWindow(clawStoreEnabled: Bool = false) -> MenuModel {
        MenuModel(
            title: "Main Menu",
            topLevelMenus: [
                TopLevelMenuModel(id: .app, title: "Soyeht", items: appMenuItems(clawStoreEnabled: clawStoreEnabled)),
                TopLevelMenuModel(id: .shell, title: "Shell", items: shellMenuItems()),
                TopLevelMenuModel(id: .edit, title: "Edit", items: editMenuItems()),
                TopLevelMenuModel(id: .view, title: "View", items: viewMenuItems()),
                TopLevelMenuModel(id: .pane, title: "Pane", items: paneMenuItems()),
                TopLevelMenuModel(id: .workspaces, title: "Workspaces", items: workspaceMenuItems()),
                TopLevelMenuModel(id: .sound, title: "Sound", tag: MainMenuTag.soundTopLevel, items: soundMenuItems()),
                TopLevelMenuModel(id: .window, title: "Window", items: windowMenuItems()),
                TopLevelMenuModel(id: .help, title: "Help", items: helpMenuItems()),
            ]
        )
    }

    private static func appMenuItems(clawStoreEnabled: Bool) -> [MenuItemModel] {
        var items: [MenuItemModel] = [
            .system(.aboutSoyeht),
            .command(.checkForUpdates),
            .separator,
            .command(.showPreferences),
            .command(.showAgentVisualPermissions),
            .command(.showPairedDevices),
            .command(.showConnectedServers),
        ]
        if clawStoreEnabled {
            items.append(.command(.showClawStore))
        }
        items.append(contentsOf: [
            .separator,
            .system(.hideSoyeht),
            .system(.hideOthers),
            .system(.showAll),
            .separator,
            .command(.uninstallSoyeht),
            .system(.quitSoyeht),
        ])
        return items
    }

    private static func shellMenuItems() -> [MenuItemModel] {
        [
            .command(.newWindow),
            .command(.newConversation),
            .separator,
            .system(.closeWindow),
            .explicit(.closeWorkspace),
            .explicit(.logout),
        ]
    }

    private static func editMenuItems() -> [MenuItemModel] {
        [
            .command(.undoWindowAction),
            .command(.redoWindowAction),
            .separator,
            .system(.cut),
            .system(.copy),
            .system(.paste),
            .system(.pasteAndMatchStyle),
            .system(.delete),
            .system(.selectAll),
            .separator,
            .system(.useOptionAsMetaKey),
            .separator,
            .submenu(id: .find, title: "Find", items: [
                .system(.find),
                .system(.findAndReplace),
                .system(.findNext),
                .system(.findPrevious),
                .system(.useSelectionForFind),
                .system(.jumpToSelection),
            ]),
            .submenu(id: .speech, title: "Speech", items: [
                .system(.startSpeaking),
                .system(.stopSpeaking),
            ]),
        ]
    }

    private static func viewMenuItems() -> [MenuItemModel] {
        [
            .explicit(.actualSize),
            .explicit(.zoomIn),
            .explicit(.zoomOut),
            .separator,
            .system(.enterFullScreen),
            .command(.showCommandPalette),
        ]
    }

    private static func paneMenuItems() -> [MenuItemModel] {
        [
            .command(.splitPaneVertical),
            .command(.splitPaneHorizontal),
            .separator,
            .command(.focusPaneLeft),
            .command(.focusPaneRight),
            .command(.focusPaneUp),
            .command(.focusPaneDown),
            .separator,
            .command(.closeFocusedPane),
            .command(.toggleZoomFocusedPane),
            .command(.exitZoom),
            .command(.swapPaneLeft),
            .command(.swapPaneRight),
            .command(.swapPaneUp),
            .command(.swapPaneDown),
            .command(.rotateFocusedSplit),
            .separator,
            .dynamic(.movePaneToWorkspace),
        ]
    }

    private static func workspaceMenuItems() -> [MenuItemModel] {
        [
            .command(.showConversationsSidebar),
            .separator,
            .dynamic(.workspaces),
            .separator,
            .command(.moveActiveWorkspaceLeft),
            .command(.moveActiveWorkspaceRight),
            .separator,
            .submenu(id: .groupActiveWorkspace, title: "Group Active Workspace", tag: AppCommandMenuTag.workspaceGroupActiveHeader, items: [
                .explicit(.assignActiveWorkspaceToNoGroup),
                .separator,
                .explicit(.newGroupForActiveWorkspace),
            ]),
        ]
    }

    private static func soundMenuItems() -> [MenuItemModel] {
        [
            .dynamic(.dictationLanguage),
        ]
    }

    private static func windowMenuItems() -> [MenuItemModel] {
        [
            .system(.minimize),
            .system(.zoom),
            .separator,
            .system(.bringAllToFront),
        ]
    }

    private static func helpMenuItems() -> [MenuItemModel] {
        [
            .system(.soyehtHelp),
        ]
    }
}
