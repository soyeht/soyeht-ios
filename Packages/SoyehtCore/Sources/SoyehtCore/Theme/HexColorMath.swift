import Foundation

/// Small color arithmetic over hex strings, used to derive design-style
/// elevation colors (neumorphic light/dark shadows, wells) from any terminal
/// theme so every user theme works with every style even without a curated
/// preset.
public enum HexColorMath {
    /// Linear RGB mix of two hex colors. `t` = 0 returns `hexA`, 1 returns `hexB`.
    public static func mix(_ hexA: String, _ hexB: String, t: Double) -> String {
        let clamped = min(1, max(0, t))
        let (ar, ag, ab) = ColorTheme.rgb8(from: hexA)
        let (br, bg, bb) = ColorTheme.rgb8(from: hexB)
        func blend(_ a: UInt8, _ b: UInt8) -> Int {
            Int((Double(a) * (1 - clamped) + Double(b) * clamped).rounded())
        }
        return String(format: "#%02X%02X%02X", blend(ar, br), blend(ag, bg), blend(ab, bb))
    }

    /// Mixes toward white by `t` (0...1).
    public static func lighten(_ hex: String, by t: Double) -> String {
        mix(hex, "#FFFFFF", t: t)
    }

    /// Mixes toward black by `t` (0...1).
    public static func darken(_ hex: String, by t: Double) -> String {
        mix(hex, "#000000", t: t)
    }

    /// Appends an alpha channel, producing #RRGGBBAA.
    public static func withAlpha(_ hex: String, _ alpha: Double) -> String {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        let a = Int((min(1, max(0, alpha)) * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", Int(r), Int(g), Int(b), a)
    }
}
