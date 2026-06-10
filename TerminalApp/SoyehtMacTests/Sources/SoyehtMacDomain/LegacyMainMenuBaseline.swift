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
        MainMenuBuilder().buildPublicNoWindowMenu(clawStoreEnabled: clawStoreEnabled)
    }

    static func snapshotOptions() -> MainMenuSnapshotOptions {
        MainMenuSnapshotOptions(redactedSubmenuTags: [
            MainMenuTag.soundDictationLanguage: "dictation languages are locale and preference dependent"
        ])
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
}
#endif
