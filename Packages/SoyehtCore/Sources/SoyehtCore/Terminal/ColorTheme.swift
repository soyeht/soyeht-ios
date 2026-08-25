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

    public var displayName: LocalizedStringResource {
        switch self {
        case .soyehtDark:
            return LocalizedStringResource(
                "theme.name.soyehtDark",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Color theme display name. 'Soyeht Dark' is the house theme."
            )
        case .solarizedDark:
            return LocalizedStringResource(
                "theme.name.solarized",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Color theme display name. 'Solarized' is a well-known color scheme by Ethan Schoonover."
            )
        case .dracula:
            return LocalizedStringResource(
                "theme.name.dracula",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Color theme display name. 'Dracula' is a well-known color scheme; treat as proper noun."
            )
        case .monokai:
            return LocalizedStringResource(
                "theme.name.monokai",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Color theme display name. 'Monokai' is a well-known color scheme; treat as proper noun."
            )
        case .highContrast:
            return LocalizedStringResource(
                "theme.name.highContrast",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Color theme display name — a high-contrast accessibility-friendly palette."
            )
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

public extension ColorTheme {
    /// As quatro cores de agente deste tema, fixadas como dado.
    ///
    /// Eram derivadas dos papeis semanticos em tempo de execucao, entao cada
    /// mudanca no codigo de derivacao restilizava temas que ja estavam
    /// aprovados. Cor aprovada e dado.
    var agentPlates: [String] {
        switch self {
        case .soyehtDark: return ["#C6EEE1", "#C2F6E9", "#FBD2D2", "#FDE8C4"]
        case .solarizedDark: return ["#E2E7C2", "#E2E7C2", "#F7CECD", "#EDE3C2"]
        case .dracula: return ["#D5FEDF", "#D5FEDF", "#FFD6D6", "#FCFEE3"]
        case .monokai: return ["#EAF8CD", "#E2EDCC", "#F1CBD8", "#EDEDCC"]
        case .highContrast: return ["#C2FFC2", "#C2FFC2", "#FFC2C2", "#FFFFC2"]
        }
    }
}

public extension ColorTheme {
    /// Os papeis neumorficos deste tema, fixados como dado.
    ///
    /// Eram calculados a partir do fundo em tempo de execucao. Qualquer ajuste
    /// nesse calculo restilizava temas ja aprovados sem que ninguem pedisse.
    /// Estes valores sao exatamente os que o calculo produzia — nada mudou de
    /// aparencia ao fixa-los.
    var neoRoles: [String: String] {
        switch self {
        case .soyehtDark:
            return ["neo.surface": "#0A0A0A", "neo.well": "#000000",
                    "neo.shadowDark": "#000000", "neo.shadowLight": "#141414",
                    "neo.accentShadow": "#10B981"]
        case .solarizedDark:
            return ["neo.surface": "#0A333E", "neo.well": "#00232C",
                    "neo.shadowDark": "#00181E", "neo.shadowLight": "#143C46",
                    "neo.accentShadow": "#859900"]
        case .dracula:
            return ["neo.surface": "#31333E", "neo.well": "#21222C",
                    "neo.shadowDark": "#16171E", "neo.shadowLight": "#393B46",
                    "neo.accentShadow": "#50FA7B"]
        case .monokai:
            return ["neo.surface": "#30312B", "neo.well": "#20211C",
                    "neo.shadowDark": "#151613", "neo.shadowLight": "#383934",
                    "neo.accentShadow": "#A6E22E"]
        case .highContrast:
            return ["neo.surface": "#0A0A0A", "neo.well": "#000000",
                    "neo.shadowDark": "#000000", "neo.shadowLight": "#141414",
                    "neo.accentShadow": "#00FF00"]
        }
    }
}
