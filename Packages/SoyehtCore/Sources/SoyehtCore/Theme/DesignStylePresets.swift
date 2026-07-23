import Foundation

/// Curated design-style preset themes.
///
/// These are ordinary built-in terminal themes whose `extraHexColors` carry
/// the reserved `app.*` / `neo.*` slots, letting the chrome palette diverge
/// from the terminal screen (a light neumorphic chrome around a dark
/// terminal). They match the Pencil reference design's three neo variants.
/// Any other theme still works with any design style via derivation — these
/// exist so the marquee looks are exact.
public extension TerminalColorTheme {
    static var designStylePresets: [TerminalColorTheme] {
        [neoMilk, neoMidnight, neoCream]
    }

    private static let neoANSI: [String] = [
        "#000000", "#EF4444", "#00D9A3", "#F59E0B",
        "#0300B2", "#B200B2", "#00A5B2", "#E5E5E5",
        "#666666", "#EF4444", "#00D9A3", "#FFAA00",
        "#0700FE", "#E500E5", "#00E5E5", "#FFFFFF",
    ]

    /// Milk is a LIGHT terminal (dark ink on milk, like the reference's
    /// `➜ ~/theyos` card): the neumorphic junction lighting only reads when
    /// the surfaces that meet are light. Midnight stays the dark-terminal
    /// home.
    private static let milkANSI: [String] = [
        "#1F2633", "#D9556A", "#2E9A73", "#B98A2E",
        "#3D7DD9", "#9A6BD0", "#2E93A6", "#8E9AB3",
        "#6E7A96", "#ED6F86", "#3FB68B", "#E9B04E",
        "#5B9DF5", "#B08CFF", "#3FB6C8", "#263043",
    ]

    static var neoMilk: TerminalColorTheme {
        TerminalColorTheme(
            id: "neoMilk",
            displayName: "Neo · Milk",
            backgroundHex: "#E8EDF4",
            foregroundHex: "#3E4A66",
            cursorHex: "#5B7CFA",
            selectionBackgroundHex: "#C9D6EE",
            ansiHex: milkANSI,
            source: .builtIn,
            extraHexColors: [
                "app.background": "#E0E5EC",
                "app.surface": "#E8EDF4",
                "app.hover": "#DCE2EA",
                "app.border": "#D8DEE8",
                "app.textPrimary": "#3E4A66",
                "app.textSecondary": "#6E7A96",
                "app.textMuted": "#8E9AB3",
                "app.accent": "#5B7CFA",
                "neo.surface": "#E8EDF4",
                "neo.well": "#D8DEE8",
                "neo.shadowDark": "#A6B4C8",
                "neo.shadowLight": "#FFFFFF",
                "neo.accentShadow": "#5B7CFA",
            ]
        )
    }

    static var neoMidnight: TerminalColorTheme {
        TerminalColorTheme(
            id: "neoMidnight",
            displayName: "Neo · Midnight",
            backgroundHex: "#101216",
            foregroundHex: "#E9ECF2",
            cursorHex: "#3EE0A6",
            ansiHex: neoANSI,
            source: .builtIn,
            extraHexColors: [
                "app.background": "#23262C",
                "app.surface": "#282C33",
                "app.hover": "#2D323A",
                "app.border": "#1D2025",
                "app.textPrimary": "#E9ECF2",
                "app.textSecondary": "#AEB4C0",
                "app.textMuted": "#8C93A3",
                "app.accent": "#3EE0A6",
                "neo.surface": "#282C33",
                "neo.well": "#1D2025",
                "neo.shadowDark": "#14161A",
                "neo.shadowLight": "#363C46",
                "neo.accentShadow": "#3EE0A6",
            ]
        )
    }

    static var neoCream: TerminalColorTheme {
        TerminalColorTheme(
            id: "neoCream",
            displayName: "Neo · Cream",
            backgroundHex: "#382E22",
            foregroundHex: "#F5EDE2",
            cursorHex: "#E07A4F",
            ansiHex: neoANSI,
            source: .builtIn,
            extraHexColors: [
                "app.background": "#EFE7DC",
                "app.surface": "#F5EEE4",
                "app.hover": "#EAE0D2",
                "app.border": "#E5DBCC",
                "app.textPrimary": "#584A3B",
                "app.textSecondary": "#84735F",
                "app.textMuted": "#A5947E",
                "app.accent": "#E07A4F",
                "neo.surface": "#F5EEE4",
                "neo.well": "#E5DBCC",
                "neo.shadowDark": "#CDBEA9",
                "neo.shadowLight": "#FFFFFF",
                "neo.accentShadow": "#E07A4F",
            ]
        )
    }
}
