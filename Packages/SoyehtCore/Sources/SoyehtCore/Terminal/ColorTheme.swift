import SwiftUI

// Note: `palette: [SwiftTerm.Color]` is NOT here — SwiftTerm is not a SoyehtCore dep.
// Each app target adds it via ColorTheme+SwiftTerm.swift extension.

public enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case soyehtDark    = "soyehtDark"
    case solarizedDark = "solarizedDark"
    case dracula       = "dracula"
    case monokai       = "monokai"
    case highContrast  = "highContrast"

    public var id: String { rawValue }

    public static var active: ColorTheme {
        ColorTheme(rawValue: TerminalPreferences.shared.colorTheme) ?? .soyehtDark
    }

    public var displayName: String {
        switch self {
        case .soyehtDark:    return "Soyeht Dark"
        case .solarizedDark: return "Solarized"
        case .dracula:       return "Dracula"
        case .monokai:       return "Monokai"
        case .highContrast:  return "High Contrast"
        }
    }

    public var backgroundHex: String {
        switch self {
        case .soyehtDark:    return "#000000"
        case .solarizedDark: return "#002B36"
        case .dracula:       return "#282A36"
        case .monokai:       return "#272822"
        case .highContrast:  return "#000000"
        }
    }

    public var foregroundHex: String {
        switch self {
        case .soyehtDark:    return "#FFFFFF"
        case .solarizedDark: return "#839496"
        case .dracula:       return "#F8F8F2"
        case .monokai:       return "#F8F8F2"
        case .highContrast:  return "#FFFFFF"
        }
    }

    public var defaultCursorHex: String {
        switch self {
        case .soyehtDark:    return "#10B981"
        case .solarizedDark: return "#859900"
        case .dracula:       return "#50FA7B"
        case .monokai:       return "#A6E22E"
        case .highContrast:  return "#00FF00"
        }
    }

    public var ansiHex: [String] {
        switch self {
        case .soyehtDark:
            return [
                "#000000", "#EF4444", "#00D9A3", "#F59E0B",
                "#0300B2", "#B200B2", "#00A5B2", "#E5E5E5",
                "#666666", "#EF4444", "#00D9A3", "#FFAA00",
                "#0700FE", "#E500E5", "#00E5E5", "#FFFFFF",
            ]
        case .solarizedDark:
            return [
                "#073642", "#DC322F", "#859900", "#B58900",
                "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                "#002B36", "#CB4B16", "#586E75", "#657B83",
                "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
            ]
        case .dracula:
            return [
                "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
                "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
                "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
            ]
        case .monokai:
            return [
                "#333333", "#C4265E", "#86B42B", "#B3B42B",
                "#6A7EC8", "#8C6BC8", "#56ADBC", "#E3E3DD",
                "#666666", "#F92672", "#A6E22E", "#E2E22E",
                "#819AFF", "#AE81FF", "#66D9EF", "#F8F8F2",
            ]
        case .highContrast:
            return [
                "#000000", "#FF0000", "#00FF00", "#FFFF00",
                "#0000FF", "#FF00FF", "#00FFFF", "#BFBFBF",
                "#808080", "#FF0000", "#00FF00", "#FFFF00",
                "#0000FF", "#FF00FF", "#00FFFF", "#FFFFFF",
            ]
        }
    }

    public var swiftUIPalette: [SwiftUI.Color] {
        ansiHex.map { SwiftUI.Color(hex: $0) }
    }

    public var previewSwatches: [SwiftUI.Color] {
        [swiftUIPalette[2], swiftUIPalette[6], swiftUIPalette[3], swiftUIPalette[1]]
    }

    // MARK: - Hex Parsing

    public static func rgb8(from hex: String) -> (UInt8, UInt8, UInt8) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgbValue: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgbValue)
        return (
            UInt8((rgbValue & 0xFF0000) >> 16),
            UInt8((rgbValue & 0x00FF00) >> 8),
            UInt8(rgbValue & 0x0000FF)
        )
    }
}
