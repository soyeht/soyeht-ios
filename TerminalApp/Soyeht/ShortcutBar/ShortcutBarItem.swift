import Foundation
import SoyehtCore

// MARK: - Kind

enum ShortcutBarItemKind: String, Codable, Equatable, Sendable {
    /// Fixed bytes sent on tap.
    case send
    /// Arrow key with auto-repeat; sequence depends on applicationCursor mode.
    case arrow
    /// Sticky Ctrl modifier toggle.
    case modifierCtrl
    /// Sticky Alt modifier toggle.
    case modifierAlt
}

// MARK: - Group (determines divider placement in the UIKit bar)

enum ShortcutBarGroup: String, Codable, Equatable, Sendable {
    case navigation  // S-Tab, /, Tab, Esc
    case arrows      // ↑↓←→
    case paging      // PgUp, PgDn
    case modifiers   // Ctrl, Alt
    case actions     // Kill, Enter
    case custom      // user-created shortcuts
}

// MARK: - Style (determines color treatment in the UIKit bar)

enum ShortcutBarStyle: String, Codable, Equatable, Sendable {
    case `default`   // white text, dark bg
    case danger      // red text, dark-red bg (Kill)
    case action      // green text, dark-green bg (Enter)
}

// MARK: - Modifier (for custom shortcut creation)

enum ShortcutBarModifier: String, Codable, Equatable, Sendable {
    case ctrl
    case alt
}

// MARK: - Item

struct ShortcutBarItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let kind: ShortcutBarItemKind
    let bytes: [UInt8]
    let group: ShortcutBarGroup
    let style: ShortcutBarStyle
    var description: String?
    var isCustom: Bool

    // MARK: - Custom Shortcut Factory

    /// Creates a custom shortcut item from modifier + key.
    /// Ctrl+letter = ascii & 0x1F (e.g. Ctrl+D = 0x04).
    /// Alt+letter = ESC prefix 0x1B followed by the character byte.
    static func customShortcut(
        modifier: ShortcutBarModifier,
        key: Character,
        label: String? = nil,
        description: String? = nil
    ) -> ShortcutBarItem {
        let lowered = key.lowercased().first ?? key
        let asciiValue = lowered.asciiValue ?? 0

        let bytes: [UInt8]
        let autoLabel: String

        switch modifier {
        case .ctrl:
            // Ctrl+letter: ASCII value & 0x1F
            bytes = [asciiValue & 0x1F]
            autoLabel = "C-\(lowered)"
        case .alt:
            // Alt+letter: ESC prefix + character
            bytes = [0x1B, asciiValue]
            autoLabel = "M-\(lowered)"
        }

        let finalLabel = (label ?? "").isEmpty ? autoLabel : label!

        return ShortcutBarItem(
            id: "custom.\(UUID().uuidString)",
            label: finalLabel,
            kind: .send,
            bytes: bytes,
            group: .custom,
            style: .default,
            description: description,
            isCustom: true
        )
    }

    /// Creates a text command shortcut that types a string when tapped.
    static func textCommand(
        text: String,
        label: String? = nil,
        description: String? = nil
    ) -> ShortcutBarItem {
        let bytes = Array(text.utf8)
        let autoLabel = text.count <= 8 ? text : String(text.prefix(7)) + "…"
        let finalLabel = (label ?? "").isEmpty ? autoLabel : label!

        return ShortcutBarItem(
            id: "custom.\(UUID().uuidString)",
            label: finalLabel,
            kind: .send,
            bytes: bytes,
            group: .custom,
            style: .default,
            description: description ?? text,
            isCustom: true
        )
    }
}
