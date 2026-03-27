//
//  KeyBarConfiguration.swift
//
//  Defines the button order, types, and byte sequences for the iOS terminal key bar.
//  This is a pure data model with no UIKit dependency, enabling unit testing.
//

/// The type of sticky modifier a key bar button represents.
public enum KeyBarModifierType: Equatable, Sendable {
    case ctrl
    case alt
}

/// The behavioral kind of a key bar item.
public enum KeyBarItemKind: Equatable, Sendable {
    /// Sends fixed bytes on tap.
    case send
    /// Arrow key with auto-repeat; sequence depends on applicationCursor mode.
    case arrow
    /// Sticky modifier toggle (Ctrl or Alt).
    case modifier(KeyBarModifierType)
    /// Visual separator, non-interactive.
    case divider
}

/// A single item in the key bar (button, arrow, modifier, or divider).
public struct KeyBarItem: Sendable {
    /// Display label. `nil` for dividers.
    public let label: String?
    /// Behavioral kind.
    public let kind: KeyBarItemKind
    /// Bytes to send on tap. Empty for dividers, modifiers, and arrows (arrows use `arrowSequence`).
    public let bytes: [UInt8]
}

/// Pure-data configuration for the terminal key bar button layout.
public enum KeyBarConfiguration {

    /// The ordered list of key bar items matching the design spec.
    public static let items: [KeyBarItem] = [
        KeyBarItem(label: "S-Tab", kind: .send,              bytes: EscapeSequences.cmdBackTab),
        KeyBarItem(label: "/",     kind: .send,              bytes: [0x2f]),
        KeyBarItem(label: nil,     kind: .divider,           bytes: []),
        KeyBarItem(label: "Tab",   kind: .send,              bytes: EscapeSequences.cmdTab),
        KeyBarItem(label: "Esc",   kind: .send,              bytes: EscapeSequences.cmdEsc),
        KeyBarItem(label: nil,     kind: .divider,           bytes: []),
        KeyBarItem(label: "↑",     kind: .arrow,             bytes: []),
        KeyBarItem(label: "↓",     kind: .arrow,             bytes: []),
        KeyBarItem(label: "←",     kind: .arrow,             bytes: []),
        KeyBarItem(label: "→",     kind: .arrow,             bytes: []),
        KeyBarItem(label: nil,     kind: .divider,           bytes: []),
        KeyBarItem(label: "Ctrl",  kind: .modifier(.ctrl),   bytes: []),
        KeyBarItem(label: "Alt",   kind: .modifier(.alt),    bytes: []),
        KeyBarItem(label: nil,     kind: .divider,           bytes: []),
        KeyBarItem(label: "Kill",  kind: .send,              bytes: [0x03]),
        KeyBarItem(label: "Enter", kind: .send,              bytes: [0x0d]),
    ]

    /// Returns the escape sequence for an arrow key label, respecting applicationCursor mode.
    public static func arrowSequence(for label: String, applicationCursor: Bool) -> [UInt8] {
        switch label {
        case "↑":
            return applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case "↓":
            return applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case "←":
            return applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case "→":
            return applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        default:
            return []
        }
    }
}
