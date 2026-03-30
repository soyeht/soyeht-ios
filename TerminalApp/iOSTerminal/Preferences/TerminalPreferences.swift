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
}
