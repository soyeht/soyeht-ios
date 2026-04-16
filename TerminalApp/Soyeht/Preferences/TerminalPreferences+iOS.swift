import Foundation
import SoyehtCore

// iOS-only preferences. Cross-platform keys (fontSize, cursorStyle, colorTheme,
// cursorColorHex, recentCustomColors, paneNicknames) live in SoyehtCore's
// TerminalPreferences. Keys here stay on iOS because they depend on iOS-only
// types (HapticZone, ShortcutBarItem, etc.).
//
// IMPORTANT: UserDefaults key strings MUST match the ones from the pre-split
// iOS-local TerminalPreferences.swift exactly — preserving user data.

extension TerminalPreferences {

    private enum IOSKeys {
        static let hapticEnabled        = "soyeht.terminal.hapticEnabled"
        static let hapticZoneConfigs    = "soyeht.terminal.hapticZoneConfigs"
        static let voiceInputEnabled    = "soyeht.terminal.voiceInputEnabled"
        static let voiceLanguage        = "soyeht.terminal.voiceLanguage"
        static let shortcutBarActiveIDs = "soyeht.terminal.shortcutBarActiveIDs"
        static let shortcutBarCustomItems = "soyeht.terminal.shortcutBarCustomItems"
    }

    // MARK: - Voice Input

    var voiceInputEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: IOSKeys.voiceInputEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: IOSKeys.voiceInputEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: IOSKeys.voiceInputEnabled) }
    }

    var voiceLanguage: String {
        get { UserDefaults.standard.string(forKey: IOSKeys.voiceLanguage) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: IOSKeys.voiceLanguage) }
    }

    // MARK: - Haptic Feedback

    var hapticEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: IOSKeys.hapticEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: IOSKeys.hapticEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: IOSKeys.hapticEnabled) }
    }

    func hapticType(for zone: HapticZone) -> HapticType {
        guard let data = UserDefaults.standard.data(forKey: IOSKeys.hapticZoneConfigs),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = dict[zone.rawValue],
              let type = HapticType(rawValue: raw) else {
            return zone.defaultType
        }
        return type
    }

    func setHapticType(_ type: HapticType, for zone: HapticZone) {
        var dict: [String: String]
        if let data = UserDefaults.standard.data(forKey: IOSKeys.hapticZoneConfigs),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = existing
        } else {
            dict = [:]
        }
        dict[zone.rawValue] = type.rawValue
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: IOSKeys.hapticZoneConfigs)
        }
    }

    // MARK: - Shortcut Bar

    var shortcutBarActiveIDs: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: IOSKeys.shortcutBarActiveIDs),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return ShortcutBarCatalog.defaultBarOrder
            }
            return ids
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: IOSKeys.shortcutBarActiveIDs)
            }
        }
    }

    var shortcutBarCustomItems: [ShortcutBarItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: IOSKeys.shortcutBarCustomItems),
                  let items = try? JSONDecoder().decode([ShortcutBarItem].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: IOSKeys.shortcutBarCustomItems)
            }
        }
    }

    func resolvedActiveItems() -> [ShortcutBarItem] {
        let custom = shortcutBarCustomItems
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
