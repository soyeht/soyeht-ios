import Foundation
import CoreGraphics

final class TerminalPreferences {
    static let shared = TerminalPreferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "soyeht.terminal.fontSize"
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
}
