import Foundation

#if canImport(AppKit)
import AppKit

struct LegacyMenuCanonicalization: Equatable {
    let label: String
    let commandID: AppCommandID?
    let storyboardSelector: String
    let canonicalSelector: String
    let storyboardTitle: String
    let canonicalTitle: String
    let storyboardShortcut: MenuShortcutSnapshot?
    let canonicalShortcut: MenuShortcutSnapshot?
    let reason: String

    var changesStoryboardContract: Bool {
        storyboardSelector != canonicalSelector
            || storyboardTitle != canonicalTitle
            || storyboardShortcut != canonicalShortcut
    }
}

enum LegacyMainMenuBaseline {
    static let soundTopLevelTag = -701
    static let soundDictationLanguageTag = -702
    static let workspaceUnavailableTag = -801
    static let paneMoveUnavailableTag = -802

    static let canonicalizations: [LegacyMenuCanonicalization] = [
        LegacyMenuCanonicalization(
            label: "App menu Settings",
            commandID: .showPreferences,
            storyboardSelector: "showPreferences:",
            canonicalSelector: AppCommandAction.showPreferences.rawValue,
            storyboardTitle: "Preferences…",
            canonicalTitle: "Settings…",
            storyboardShortcut: shortcut(",", [.command]),
            canonicalShortcut: shortcut(",", [.command]),
            reason: "Public macOS label is Settings; storyboard still carries the historical Preferences title."
        ),
        LegacyMenuCanonicalization(
            label: "Workspace sidebar",
            commandID: .showConversationsSidebar,
            storyboardSelector: "showConversationsSidebar:",
            canonicalSelector: AppCommandAction.showConversationsSidebar.rawValue,
            storyboardTitle: "Conversations Sidebar",
            canonicalTitle: "Show Workspace Sidebar",
            storyboardShortcut: shortcut("c", [.command, .shift]),
            canonicalShortcut: shortcut("c", [.command, .shift]),
            reason: "The product surface uses Workspaces terminology; storyboard still says Conversations."
        ),
        LegacyMenuCanonicalization(
            label: "View actual size",
            commandID: nil,
            storyboardSelector: "defaultFontSize:",
            canonicalSelector: "defaultFontSize:",
            storyboardTitle: "Default Font Size",
            canonicalTitle: "Actual Size",
            storyboardShortcut: shortcut("0", [.command]),
            canonicalShortcut: shortcut("0", [.command]),
            reason: "View menu labels were normalized to standard macOS zoom language."
        ),
        LegacyMenuCanonicalization(
            label: "View zoom in",
            commandID: nil,
            storyboardSelector: "biggerFont:",
            canonicalSelector: "biggerFont:",
            storyboardTitle: "Bigger",
            canonicalTitle: "Zoom In",
            storyboardShortcut: shortcut("+", [.command]),
            canonicalShortcut: shortcut("+", [.command]),
            reason: "View menu labels were normalized to standard macOS zoom language."
        ),
        LegacyMenuCanonicalization(
            label: "View zoom out",
            commandID: nil,
            storyboardSelector: "smallerFont:",
            canonicalSelector: "smallerFont:",
            storyboardTitle: "Smaller",
            canonicalTitle: "Zoom Out",
            storyboardShortcut: shortcut("-", [.command]),
            canonicalShortcut: shortcut("-", [.command]),
            reason: "View menu labels were normalized to standard macOS zoom language."
        ),
        LegacyMenuCanonicalization(
            label: "Edit redo",
            commandID: .redoWindowAction,
            storyboardSelector: "redo:",
            canonicalSelector: AppCommandAction.redoWindowAction.rawValue,
            storyboardTitle: "Redo",
            canonicalTitle: "Redo",
            storyboardShortcut: shortcut("z", [.command, .shift]),
            canonicalShortcut: shortcut("y", [.command]),
            reason: "Undo/redo route to the active workspace undo manager; registry shortcut is the final runtime contract."
        ),
        LegacyMenuCanonicalization(
            label: "Pane focus left",
            commandID: .focusPaneLeft,
            storyboardSelector: "focusPaneLeft:",
            canonicalSelector: AppCommandAction.focusPaneLeft.rawValue,
            storyboardTitle: "Focus Left",
            canonicalTitle: "Focus Left",
            storyboardShortcut: shortcut("leftArrow", [.command, .option]),
            canonicalShortcut: shortcut("leftArrow", [.command, .shift]),
            reason: "Pane navigation uses the registry shortcut after runtime normalization."
        ),
        LegacyMenuCanonicalization(
            label: "Pane focus right",
            commandID: .focusPaneRight,
            storyboardSelector: "focusPaneRight:",
            canonicalSelector: AppCommandAction.focusPaneRight.rawValue,
            storyboardTitle: "Focus Right",
            canonicalTitle: "Focus Right",
            storyboardShortcut: shortcut("rightArrow", [.command, .option]),
            canonicalShortcut: shortcut("rightArrow", [.command, .shift]),
            reason: "Pane navigation uses the registry shortcut after runtime normalization."
        ),
        LegacyMenuCanonicalization(
            label: "Pane focus up",
            commandID: .focusPaneUp,
            storyboardSelector: "focusPaneUp:",
            canonicalSelector: AppCommandAction.focusPaneUp.rawValue,
            storyboardTitle: "Focus Up",
            canonicalTitle: "Focus Up",
            storyboardShortcut: shortcut("upArrow", [.command, .option]),
            canonicalShortcut: shortcut("upArrow", [.command, .shift]),
            reason: "Pane navigation uses the registry shortcut after runtime normalization."
        ),
        LegacyMenuCanonicalization(
            label: "Pane focus down",
            commandID: .focusPaneDown,
            storyboardSelector: "focusPaneDown:",
            canonicalSelector: AppCommandAction.focusPaneDown.rawValue,
            storyboardTitle: "Focus Down",
            canonicalTitle: "Focus Down",
            storyboardShortcut: shortcut("downArrow", [.command, .option]),
            canonicalShortcut: shortcut("downArrow", [.command, .shift]),
            reason: "Pane navigation uses the registry shortcut after runtime normalization."
        ),
        LegacyMenuCanonicalization(
            label: "Pane close",
            commandID: .closeFocusedPane,
            storyboardSelector: "closePaneOrWindow:",
            canonicalSelector: AppCommandAction.closeFocusedPane.rawValue,
            storyboardTitle: "Close Pane",
            canonicalTitle: "Close Pane",
            storyboardShortcut: shortcut("w", [.command, .shift]),
            canonicalShortcut: nil,
            reason: "Shift-Command-W is reserved for Shell > Close Workspace; Close Pane is click-only in the current public menu."
        ),
    ]

    /// Builds a structural snapshot target for the current public menu surface.
    ///
    /// This is a PR-1 safety net, not a full `NSMenuItemValidation` oracle:
    /// commands that are context-dependent may appear structurally even in the
    /// no-window baseline. PR-2 owns moving that enabled/disabled behavior into
    /// descriptor-level `CommandUIContext` validation.
    static func makePublicNoWindowMenu(clawStoreEnabled: Bool = false) -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        addTopLevel("Soyeht", to: mainMenu, items: appMenuItems(clawStoreEnabled: clawStoreEnabled))
        addTopLevel("Shell", to: mainMenu, items: shellMenuItems())
        addTopLevel("Edit", to: mainMenu, items: editMenuItems())
        addTopLevel("View", to: mainMenu, items: viewMenuItems())
        addTopLevel("Pane", to: mainMenu, items: paneMenuItems())
        addTopLevel("Workspaces", to: mainMenu, items: workspaceMenuItems())
        addTopLevel("Sound", to: mainMenu, tag: soundTopLevelTag, items: soundMenuItems())
        addTopLevel("Window", to: mainMenu, items: windowMenuItems())
        addTopLevel("Help", to: mainMenu, items: helpMenuItems())
        return mainMenu
    }

    static func snapshotOptions() -> MainMenuSnapshotOptions {
        MainMenuSnapshotOptions(redactedSubmenuTags: [
            soundDictationLanguageTag: "dictation languages are locale and preference dependent"
        ])
    }

    private static func appMenuItems(clawStoreEnabled: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            system("About Soyeht", action: "orderFrontStandardAboutPanel:"),
            command(.checkForUpdates, title: "Check for Updates…"),
            .separator(),
            command(.showPreferences, title: "Settings…"),
            command(.showAgentVisualPermissions, title: "Agent Permissions…"),
            command(.showPairedDevices, title: "Paired Devices…"),
            command(.showConnectedServers, title: "Connected Servers…"),
        ]
        if clawStoreEnabled {
            items.append(command(.showClawStore, title: "Claw Store…"))
        }
        items.append(contentsOf: [
            .separator(),
            system("Hide Soyeht", action: "hide:", shortcut: shortcut("h", [.command])),
            system("Hide Others", action: "hideOtherApplications:", shortcut: shortcut("h", [.command, .option])),
            system("Show All", action: "unhideAllApplications:"),
            .separator(),
            command(.uninstallSoyeht, title: "Uninstall Soyeht…"),
            system("Quit Soyeht", action: "terminate:", shortcut: shortcut("q", [.command])),
        ])
        return items
    }

    private static func shellMenuItems() -> [NSMenuItem] {
        [
            command(.newWindow, title: "New Window"),
            command(.newConversation, title: "New Conversation"),
            .separator(),
            system("Close", action: "performClose:", shortcut: shortcut("w", [.command])),
            explicit("Close Workspace", action: "closeActiveWorkspace:", shortcut: shortcut("w", [.command, .shift])),
            explicit("Logout…", action: "logout:"),
        ]
    }

    private static func editMenuItems() -> [NSMenuItem] {
        [
            command(.undoWindowAction, title: "Undo"),
            command(.redoWindowAction, title: "Redo"),
            .separator(),
            system("Cut", action: "cut:", shortcut: shortcut("x", [.command])),
            system("Copy", action: "copy:", shortcut: shortcut("c", [.command])),
            system("Paste", action: "paste:", shortcut: shortcut("v", [.command])),
            system("Paste and Match Style", action: "pasteAsPlainText:", shortcut: shortcut("v", [.command, .option])),
            system("Delete", action: "delete:"),
            system("Select All", action: "selectAll:", shortcut: shortcut("a", [.command])),
            .separator(),
            system("Use Option as Meta Key", action: "toggleOptionAsMetaKey:", shortcut: shortcut("o", [.command, .option]), state: .on),
            .separator(),
            submenu("Find", items: [
                system("Find…", action: "performFindPanelAction:", shortcut: shortcut("f", [.command]), tag: 1),
                system("Find and Replace…", action: "performFindPanelAction:", shortcut: shortcut("f", [.command, .option]), tag: 12),
                system("Find Next", action: "performFindPanelAction:", shortcut: shortcut("g", [.command]), tag: 2),
                system("Find Previous", action: "performFindPanelAction:", shortcut: shortcut("g", [.command, .shift]), tag: 3),
                system("Use Selection for Find", action: "performFindPanelAction:", shortcut: shortcut("e", [.command]), tag: 7),
                system("Jump to Selection", action: "centerSelectionInVisibleArea:", shortcut: shortcut("j", [.command])),
            ]),
            submenu("Speech", items: [
                system("Start Speaking", action: "startSpeaking:"),
                system("Stop Speaking", action: "stopSpeaking:"),
            ]),
        ]
    }

    private static func viewMenuItems() -> [NSMenuItem] {
        [
            explicit("Actual Size", action: "defaultFontSize:", shortcut: shortcut("0", [.command])),
            explicit("Zoom In", action: "biggerFont:", shortcut: shortcut("+", [.command])),
            explicit("Zoom Out", action: "smallerFont:", shortcut: shortcut("-", [.command])),
            .separator(),
            system("Enter Full Screen", action: "toggleFullScreen:", shortcut: shortcut("f", [.command, .control])),
            command(.showCommandPalette, title: "Go to Pane…"),
        ]
    }

    private static func paneMenuItems() -> [NSMenuItem] {
        let moveHeader = submenu("Move Pane to Workspace", tag: AppCommandMenuTag.paneMoveToWorkspaceHeader, items: [
            disabled("No Focused Pane", tag: paneMoveUnavailableTag)
        ])
        moveHeader.isEnabled = false
        return [
            command(.splitPaneVertical, title: "Split Vertical"),
            command(.splitPaneHorizontal, title: "Split Horizontal"),
            .separator(),
            command(.focusPaneLeft, title: "Focus Left"),
            command(.focusPaneRight, title: "Focus Right"),
            command(.focusPaneUp, title: "Focus Up"),
            command(.focusPaneDown, title: "Focus Down"),
            .separator(),
            command(.closeFocusedPane, title: "Close Pane"),
            command(.toggleZoomFocusedPane, title: "Zoom Focused Pane"),
            command(.exitZoom, title: "Exit Zoom"),
            command(.swapPaneLeft, title: "Swap Pane Left"),
            command(.swapPaneRight, title: "Swap Pane Right"),
            command(.swapPaneUp, title: "Swap Pane Up"),
            command(.swapPaneDown, title: "Swap Pane Down"),
            command(.rotateFocusedSplit, title: "Rotate Focused Split"),
            .separator(),
            moveHeader,
        ]
    }

    private static func workspaceMenuItems() -> [NSMenuItem] {
        [
            command(.showConversationsSidebar, title: "Show Workspace Sidebar"),
            .separator(),
            disabled("No Workspace Window", tag: workspaceUnavailableTag),
            .separator(),
            command(.moveActiveWorkspaceLeft, title: "Move Active Workspace Left"),
            command(.moveActiveWorkspaceRight, title: "Move Active Workspace Right"),
            .separator(),
            submenu("Group Active Workspace", tag: AppCommandMenuTag.workspaceGroupActiveHeader, items: [
                explicit("None", action: "assignActiveWorkspaceToGroup:", state: .on, enabled: false),
                .separator(),
                explicit("New Group…", action: "newGroupForActiveWorkspace:", enabled: false),
            ]),
        ]
    }

    private static func soundMenuItems() -> [NSMenuItem] {
        [
            submenu("Dictation Language", tag: soundDictationLanguageTag, items: [])
        ]
    }

    private static func windowMenuItems() -> [NSMenuItem] {
        [
            system("Minimize", action: "performMiniaturize:", shortcut: shortcut("m", [.command])),
            system("Zoom", action: "performZoom:"),
            .separator(),
            system("Bring All to Front", action: "arrangeInFront:"),
        ]
    }

    private static func helpMenuItems() -> [NSMenuItem] {
        [
            system("Soyeht Help", action: "showHelp:", shortcut: shortcut("?", [.command]))
        ]
    }

    private static func addTopLevel(_ title: String, to mainMenu: NSMenu, tag: Int = 0, items: [NSMenuItem]) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        mainMenu.addItem(item)
    }

    private static func command(_ id: AppCommandID, title: String) -> NSMenuItem {
        guard let command = AppCommandRegistry.command(id) else {
            preconditionFailure("Missing command \(id)")
        }
        let item = explicit(title, action: command.action.rawValue, shortcut: command.shortcut.map(MenuShortcutSnapshot.init))
        if let tag = command.tag {
            item.tag = tag
        }
        return item
    }

    private static func explicit(
        _ title: String,
        action: String,
        shortcut: MenuShortcutSnapshot? = nil,
        tag: Int = 0,
        state: NSControl.StateValue = .off,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
        item.target = ExplicitMenuTarget.shared
        configure(item, shortcut: shortcut, tag: tag, state: state, enabled: enabled)
        return item
    }

    private static func system(
        _ title: String,
        action: String,
        shortcut: MenuShortcutSnapshot? = nil,
        tag: Int = 0,
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
        configure(item, shortcut: shortcut, tag: tag, state: state, enabled: true)
        return item
    }

    private static func disabled(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        item.isEnabled = false
        return item
    }

    private static func submenu(_ title: String, tag: Int = 0, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func configure(
        _ item: NSMenuItem,
        shortcut: MenuShortcutSnapshot?,
        tag: Int,
        state: NSControl.StateValue,
        enabled: Bool
    ) {
        if let shortcut {
            item.keyEquivalent = menuKeyEquivalent(for: shortcut.key)
            item.keyEquivalentModifierMask = modifierFlags(for: shortcut.modifiers)
        }
        item.tag = tag
        item.state = state
        item.isEnabled = enabled
    }

    private enum ShortcutModifier {
        case command
        case shift
        case option
        case control

        var name: String {
            switch self {
            case .command: return "command"
            case .shift: return "shift"
            case .option: return "option"
            case .control: return "control"
            }
        }
    }

    private static func shortcut(_ key: String, _ modifiers: [ShortcutModifier]) -> MenuShortcutSnapshot {
        MenuShortcutSnapshot(key: key, modifiers: modifiers.map(\.name))
    }

    private static func menuKeyEquivalent(for key: String) -> String {
        switch key {
        case "upArrow": return "\u{F700}"
        case "downArrow": return "\u{F701}"
        case "leftArrow": return "\u{F702}"
        case "rightArrow": return "\u{F703}"
        case "escape": return "\u{1B}"
        default: return key
        }
    }

    private static func modifierFlags(for modifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("command") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("control") { flags.insert(.control) }
        return flags
    }
}

private final class ExplicitMenuTarget: NSObject {
    static let shared = ExplicitMenuTarget()
}
#endif
