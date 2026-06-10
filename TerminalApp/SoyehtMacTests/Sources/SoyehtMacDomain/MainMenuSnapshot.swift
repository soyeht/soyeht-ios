import Foundation

#if canImport(AppKit)
import AppKit

struct MenuShortcutSnapshot: Codable, Equatable, Hashable {
    let key: String
    let modifiers: [String]

    init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ shortcut: AppCommandShortcut) {
        self.key = Self.snapshotKey(for: shortcut.key)
        self.modifiers = shortcut.modifiers.snapshotNames
    }

    init?(menuItem: NSMenuItem) {
        guard !menuItem.keyEquivalent.isEmpty else { return nil }
        self.key = Self.snapshotKey(forMenuKeyEquivalent: menuItem.keyEquivalent)
        self.modifiers = menuItem.keyEquivalentModifierMask.snapshotNames
    }

    private static func snapshotKey(for key: AppCommandKey) -> String {
        switch key {
        case .character(let value):
            return value.lowercased()
        case .special(let key):
            return key.snapshotName
        }
    }

    static func snapshotKey(forMenuKeyEquivalent keyEquivalent: String) -> String {
        switch keyEquivalent {
        case "\u{F700}": return "upArrow"
        case "\u{F701}": return "downArrow"
        case "\u{F702}": return "leftArrow"
        case "\u{F703}": return "rightArrow"
        case "\u{1B}": return "escape"
        default:
            return keyEquivalent.lowercased()
        }
    }
}

struct MainMenuSnapshotNode: Codable, Equatable {
    let kind: String
    let title: String?
    let action: String?
    let targetPolicy: String?
    let shortcut: MenuShortcutSnapshot?
    let tag: Int?
    let state: String?
    let enabled: Bool?
    let childrenRedacted: String?
    let children: [MainMenuSnapshotNode]?
}

struct MainMenuSnapshotOptions {
    var redactedSubmenuTags: [Int: String] = [:]
}

enum MainMenuSnapshot {
    static func capture(_ menu: NSMenu, options: MainMenuSnapshotOptions = MainMenuSnapshotOptions()) -> MainMenuSnapshotNode {
        MainMenuSnapshotNode(
            kind: "menu",
            title: menu.title,
            action: nil,
            targetPolicy: nil,
            shortcut: nil,
            tag: nil,
            state: nil,
            enabled: nil,
            childrenRedacted: nil,
            children: menu.items.map { itemNode($0, options: options) }
        )
    }

    static func encode(_ snapshot: MainMenuSnapshotNode) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(snapshot, .init(
                codingPath: [],
                debugDescription: "Menu snapshot did not encode as UTF-8."
            ))
        }
        return value + "\n"
    }

    static func decode(_ data: Data) throws -> MainMenuSnapshotNode {
        try JSONDecoder().decode(MainMenuSnapshotNode.self, from: data)
    }

    static func titles(in snapshot: MainMenuSnapshotNode) -> [String] {
        var values: [String] = []
        collectTitles(in: snapshot, into: &values)
        return values
    }

    private static func itemNode(_ item: NSMenuItem, options: MainMenuSnapshotOptions) -> MainMenuSnapshotNode {
        if item.isSeparatorItem {
            return MainMenuSnapshotNode(
                kind: "separator",
                title: nil,
                action: nil,
                targetPolicy: nil,
                shortcut: nil,
                tag: nil,
                state: nil,
                enabled: nil,
                childrenRedacted: nil,
                children: nil
            )
        }

        let rawAction = item.action.map { NSStringFromSelector($0) }
        let isSubmenuContainer = item.submenu != nil && rawAction == "submenuAction:"
        let action = isSubmenuContainer ? nil : rawAction
        let redaction = options.redactedSubmenuTags[item.tag]
        let children: [MainMenuSnapshotNode]?
        if redaction == nil, let submenu = item.submenu {
            children = submenu.items.map { itemNode($0, options: options) }
        } else {
            children = nil
        }

        return MainMenuSnapshotNode(
            kind: "item",
            title: item.title,
            action: action,
            targetPolicy: action.map { _ in item.target == nil ? "responderChain" : "explicitTarget" },
            shortcut: MenuShortcutSnapshot(menuItem: item),
            tag: item.tag == 0 ? nil : item.tag,
            state: snapshotState(for: item),
            enabled: item.isEnabled ? nil : false,
            childrenRedacted: redaction,
            children: children
        )
    }

    private static func snapshotState(for item: NSMenuItem) -> String? {
        switch item.state {
        case .off: return nil
        case .on: return "on"
        case .mixed: return "mixed"
        default: return "\(item.state.rawValue)"
        }
    }

    private static func collectTitles(in snapshot: MainMenuSnapshotNode, into values: inout [String]) {
        if let title = snapshot.title, !title.isEmpty {
            values.append(title)
        }
        snapshot.children?.forEach { collectTitles(in: $0, into: &values) }
    }
}

private extension AppCommandSpecialKey {
    var snapshotName: String {
        switch self {
        case .leftArrow: return "leftArrow"
        case .rightArrow: return "rightArrow"
        case .upArrow: return "upArrow"
        case .downArrow: return "downArrow"
        case .escape: return "escape"
        }
    }
}

private extension AppCommandModifier {
    var snapshotNames: [String] {
        var values: [String] = []
        if contains(.command) { values.append("command") }
        if contains(.shift) { values.append("shift") }
        if contains(.option) { values.append("option") }
        if contains(.control) { values.append("control") }
        return values
    }
}

private extension NSEvent.ModifierFlags {
    var snapshotNames: [String] {
        var values: [String] = []
        if contains(.command) { values.append("command") }
        if contains(.shift) { values.append("shift") }
        if contains(.option) { values.append("option") }
        if contains(.control) { values.append("control") }
        return values
    }
}
#endif
