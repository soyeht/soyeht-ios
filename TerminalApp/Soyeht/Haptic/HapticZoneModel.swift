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
        case .disabled: return String(localized: "haptic.type.disabled", comment: "HapticType shown in the zone picker — tapped to disable haptics on this zone.")
        default: return ".\(rawValue)"  // i18n-exempt: UIKit framework enum case name (light, medium, heavy, selectionChanged, success, etc.)
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
    case alphanumeric, clicky, tactile, gestures, voice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alphanumeric: return String(localized: "haptic.zone.alphanumeric", comment: "Haptic zone name — the alphanumeric keyboard row. Triggered on each key tap.")
        case .clicky: return String(localized: "haptic.zone.clicky", comment: "Haptic zone name — hard-press action keys (Enter, Kill).")
        case .tactile: return String(localized: "haptic.zone.tactile", comment: "Haptic zone name — navigation / modifier keys (Tab, Esc, arrows, Ctrl, Alt).")
        case .gestures: return String(localized: "haptic.zone.gestures", comment: "Haptic zone name — swipe gestures between panes.")
        case .voice: return String(localized: "haptic.zone.voiceInput", comment: "Haptic zone name — voice recording record/send/cancel actions.")
        }
    }

    var icon: String {
        switch self {
        case .alphanumeric: return "keyboard"
        case .clicky: return "circle.circle"
        case .tactile: return "point.3.connected.trianglepath.dotted"
        case .gestures: return "hand.raised"
        case .voice: return "mic.fill"
        }
    }

    var iconColorHex: String {
        switch self {
        case .alphanumeric: return "#6B7280"
        case .clicky: return "#3B82F6"
        case .tactile: return "#A78BFA"
        case .gestures: return "#F59E0B"
        case .voice: return "#06B6D4"
        }
    }

    var defaultType: HapticType {
        switch self {
        case .alphanumeric: return .light
        case .clicky: return .heavy
        case .tactile: return .medium
        case .gestures: return .selectionChanged
        case .voice: return .medium
        }
    }

    var keyLabels: [String] {
        switch self {
        case .alphanumeric: return ["a-z", "0-9", "\u{232B}"]
        case .clicky: return ["Enter", "Kill"]
        case .tactile: return ["Tab", "Esc", "Ctrl", "Alt", "\u{2191}\u{2193}\u{2190}\u{2192}", "S-Tab", "/"]
        case .gestures: return ["swipe pane"]
        case .voice: return ["record", "lock", "send", "cancel"]
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
        "voiceRecord": .voice,
        "voiceSend": .voice, "voiceCancel": .voice,
    ]

    static func zone(for key: String) -> HapticZone? {
        keyZoneMap[key]
    }
}
