import Foundation

// MARK: - Haptic Type

enum HapticType: String, CaseIterable, Codable, Equatable, Sendable {
    // UIImpactFeedbackGenerator
    case light, medium, heavy, soft, rigid
    // UISelectionFeedbackGenerator
    case selectionChanged
    // UINotificationFeedbackGenerator
    case success, warning, error
    // Disabled
    case disabled

    var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        default: return ".\(rawValue)"
        }
    }

    var category: Category {
        switch self {
        case .light, .medium, .heavy, .soft, .rigid: return .impact
        case .selectionChanged: return .selection
        case .success, .warning, .error: return .notification
        case .disabled: return .none
        }
    }

    enum Category: String, CaseIterable {
        case impact, selection, notification, none

        var header: String? {
            switch self {
            case .impact: return "// UIImpactFeedbackGenerator"
            case .selection: return "// UISelectionFeedbackGenerator"
            case .notification: return "// UINotificationFeedbackGenerator"
            case .none: return nil
            }
        }
    }

    static let groupedOptions: [(category: Category, types: [HapticType])] = [
        (.impact, [.light, .medium, .heavy, .soft, .rigid]),
        (.selection, [.selectionChanged]),
        (.notification, [.success, .warning, .error]),
        (.none, [.disabled]),
    ]
}

// MARK: - Haptic Zone

enum HapticZone: String, CaseIterable, Identifiable, Codable, Sendable {
    case alphanumeric, clicky, tactile, gestures

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alphanumeric: return "Alphanumeric"
        case .clicky: return "Clicky"
        case .tactile: return "Tactile"
        case .gestures: return "Gestures"
        }
    }

    var icon: String {
        switch self {
        case .alphanumeric: return "keyboard"
        case .clicky: return "circle.circle"
        case .tactile: return "point.3.connected.trianglepath.dotted"
        case .gestures: return "hand.raised"
        }
    }

    var iconColorHex: String {
        switch self {
        case .alphanumeric: return "#6B7280"
        case .clicky: return "#3B82F6"
        case .tactile: return "#A78BFA"
        case .gestures: return "#F59E0B"
        }
    }

    var defaultType: HapticType {
        switch self {
        case .alphanumeric: return .light
        case .clicky: return .heavy
        case .tactile: return .medium
        case .gestures: return .selectionChanged
        }
    }

    var keyLabels: [String] {
        switch self {
        case .alphanumeric: return ["a-z", "0-9", "\u{232B}"]
        case .clicky: return ["Enter", "Kill"]
        case .tactile: return ["Tab", "Esc", "Ctrl", "Alt", "\u{2191}\u{2193}\u{2190}\u{2192}", "S-Tab", "/"]
        case .gestures: return ["swipe pane"]
        }
    }

    // MARK: - Key-to-Zone Mapping

    /// Maps shortcut bar key labels to zones.
    /// Note: alphanumeric zone has no entries here — it is triggered
    /// directly via TerminalView.onSoftKeyboardInput for the iOS keyboard.
    static let keyZoneMap: [String: HapticZone] = [
        "Enter": .clicky, "Kill": .clicky,
        "S-Tab": .tactile, "/": .tactile,
        "Tab": .tactile, "Esc": .tactile, "Ctrl": .tactile, "Alt": .tactile,
        "\u{2191}": .tactile, "\u{2193}": .tactile, "\u{2190}": .tactile, "\u{2192}": .tactile,
        "PgUp": .tactile, "PgDn": .tactile,
        "scrollTmux": .tactile,
        "paneSwipe": .gestures,
    ]

    static func zone(for key: String) -> HapticZone? {
        keyZoneMap[key]
    }
}
