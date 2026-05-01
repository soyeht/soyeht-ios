import Foundation
import CoreGraphics

// Cross-platform preferences only. iOS-only prefs (haptic, voice, shortcutBar)
// are added via extension in the iOS target.

public final class TerminalPreferences {
    public static let shared = TerminalPreferences()
    public static let defaultFontSize: CGFloat = 13
    public static let minimumFontSize: CGFloat = 12

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "soyeht.terminal.fontSize"
        static let cursorStyle = "soyeht.terminal.cursorStyle"
        static let cursorColorHex = "soyeht.terminal.cursorColorHex"
        static let recentCustomColors = "soyeht.terminal.recentCustomColors"
        static let colorTheme = "soyeht.terminal.colorTheme"
        static let paneNicknames = "soyeht.terminal.paneNicknames"
    }

    public init() {}

    public var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: Keys.fontSize)
            return Self.normalizedFontSize(CGFloat(v))
        }
        set {
            defaults.set(Self.normalizedFontSize(newValue), forKey: Keys.fontSize)
        }
    }

    public static func normalizedFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite, size > 0 else { return defaultFontSize }
        return max(minimumFontSize, size)
    }

    public var cursorStyle: String {
        get { defaults.string(forKey: Keys.cursorStyle) ?? "blinkBlock" }
        set { defaults.set(newValue, forKey: Keys.cursorStyle) }
    }

    public var cursorColorHex: String {
        get { defaults.string(forKey: Keys.cursorColorHex) ?? "#10B981" }
        set { defaults.set(newValue, forKey: Keys.cursorColorHex) }
    }

    public var recentCustomColors: [String] {
        get { defaults.stringArray(forKey: Keys.recentCustomColors) ?? [] }
        set { defaults.set(Array(newValue.prefix(5)), forKey: Keys.recentCustomColors) }
    }

    public func addRecentCustomColor(_ hex: String) {
        var recent = recentCustomColors
        recent.removeAll { $0.caseInsensitiveCompare(hex) == .orderedSame }
        recent.insert(hex, at: 0)
        recentCustomColors = Array(recent.prefix(5))
    }

    public var colorTheme: String {
        get { defaults.string(forKey: Keys.colorTheme) ?? "soyehtDark" }
        set { defaults.set(newValue, forKey: Keys.colorTheme) }
    }

    // MARK: - Pane Nicknames

    private var paneNicknamesDict: [String: String] {
        get {
            guard let data = defaults.data(forKey: Keys.paneNicknames),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.paneNicknames)
            }
        }
    }

    private func paneKey(container: String, session: String, window: Int, paneId: Int) -> String {
        "\(container):\(session):\(window):pid:\(paneId)"
    }

    public func paneNickname(container: String, session: String, window: Int, paneId: Int) -> String? {
        paneNicknamesDict[paneKey(container: container, session: session, window: window, paneId: paneId)]
    }

    public func setPaneNickname(_ name: String?, container: String, session: String, window: Int, paneId: Int) {
        var dict = paneNicknamesDict
        let key = paneKey(container: container, session: session, window: window, paneId: paneId)
        dict[key] = name
        paneNicknamesDict = dict
    }
}
