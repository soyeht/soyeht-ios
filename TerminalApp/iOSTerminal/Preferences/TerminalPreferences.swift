import Foundation
import CoreGraphics

final class TerminalPreferences {
    static let shared = TerminalPreferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "soyeht.terminal.fontSize"
        static let cursorStyle = "soyeht.terminal.cursorStyle"
        static let cursorColorHex = "soyeht.terminal.cursorColorHex"
        static let recentCustomColors = "soyeht.terminal.recentCustomColors"
        static let hapticEnabled = "soyeht.terminal.hapticEnabled"
        static let hapticZoneConfigs = "soyeht.terminal.hapticZoneConfigs"
        static let colorTheme = "soyeht.terminal.colorTheme"
        static let voiceInputEnabled = "soyeht.terminal.voiceInputEnabled"
        static let voiceLanguage = "soyeht.terminal.voiceLanguage"
        static let shortcutBarActiveIDs = "soyeht.terminal.shortcutBarActiveIDs"
        static let shortcutBarCustomItems = "soyeht.terminal.shortcutBarCustomItems"
    }

    var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: Keys.fontSize)
            return v > 0 ? v : 13
        }
        set {
            defaults.set(newValue, forKey: Keys.fontSize)
        }
    }

    var cursorStyle: String {
        get { defaults.string(forKey: Keys.cursorStyle) ?? "blinkBlock" }
        set { defaults.set(newValue, forKey: Keys.cursorStyle) }
    }

    var cursorColorHex: String {
        get { defaults.string(forKey: Keys.cursorColorHex) ?? "#10B981" }
        set { defaults.set(newValue, forKey: Keys.cursorColorHex) }
    }

    var recentCustomColors: [String] {
        get { defaults.stringArray(forKey: Keys.recentCustomColors) ?? [] }
        set { defaults.set(Array(newValue.prefix(5)), forKey: Keys.recentCustomColors) }
    }

    func addRecentCustomColor(_ hex: String) {
        var recent = recentCustomColors
        recent.removeAll { $0.caseInsensitiveCompare(hex) == .orderedSame }
        recent.insert(hex, at: 0)
        recentCustomColors = Array(recent.prefix(5))
    }

    // MARK: - Color Theme

    var colorTheme: String {
        get { defaults.string(forKey: Keys.colorTheme) ?? "soyehtDark" }
        set { defaults.set(newValue, forKey: Keys.colorTheme) }
    }

    // MARK: - Voice Input

    var voiceInputEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.voiceInputEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.voiceInputEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.voiceInputEnabled) }
    }

    var voiceLanguage: String {
        get { defaults.string(forKey: Keys.voiceLanguage) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.voiceLanguage) }
    }

    // MARK: - Haptic Feedback

    var hapticEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.hapticEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.hapticEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.hapticEnabled) }
    }

    func hapticType(for zone: HapticZone) -> HapticType {
        guard let data = defaults.data(forKey: Keys.hapticZoneConfigs),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = dict[zone.rawValue],
              let type = HapticType(rawValue: raw) else {
            return zone.defaultType
        }
        return type
    }

    func setHapticType(_ type: HapticType, for zone: HapticZone) {
        var dict: [String: String]
        if let data = defaults.data(forKey: Keys.hapticZoneConfigs),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = existing
        } else {
            dict = [:]
        }
        dict[zone.rawValue] = type.rawValue
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Keys.hapticZoneConfigs)
        }
    }

    // MARK: - Shortcut Bar

    var shortcutBarActiveIDs: [String] {
        get {
            guard let data = defaults.data(forKey: Keys.shortcutBarActiveIDs),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return ShortcutBarCatalog.defaultBarOrder
            }
            return ids
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.shortcutBarActiveIDs)
            }
        }
    }

    var shortcutBarCustomItems: [ShortcutBarItem] {
        get {
            guard let data = defaults.data(forKey: Keys.shortcutBarCustomItems),
                  let items = try? JSONDecoder().decode([ShortcutBarItem].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.shortcutBarCustomItems)
            }
        }
    }

    /// Resolves active IDs into concrete ShortcutBarItems, skipping unknown IDs.
    func resolvedActiveItems() -> [ShortcutBarItem] {
        let custom = shortcutBarCustomItems
        // Collect all preset extra items so preset-specific IDs resolve
        let presetExtras = WorkflowPreset.allCases.flatMap(\.extraItems)
        let allCustom = custom + presetExtras
        return shortcutBarActiveIDs.compactMap { id in
            ShortcutBarCatalog.resolve(id: id, customItems: allCustom)
        }
    }

    var shortcutBarLabel: String {
        shortcutBarActiveIDs == ShortcutBarCatalog.defaultBarOrder
            ? "Default"
            : "Custom (\(shortcutBarActiveIDs.count))"
    }
}
