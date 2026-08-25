import Foundation

/// The reference neumorphic preset.
///
/// An ordinary built-in terminal theme whose `extraHexColors` carry the
/// reserved `app.*` / `neo.*` slots, so the chrome palette can diverge from
/// the terminal screen. Any other theme still works with any design style via
/// derivation — this one exists so the reference look is exact. The pane-color
/// presets live in `NeoPanePresets`.
public extension TerminalColorTheme {
    static var designStylePresets: [TerminalColorTheme] {
        [neoMilk] + neoPanePresets
    }

    /// Milk is a LIGHT terminal (dark ink on milk, like the reference's
    /// `➜ ~/theyos` card): the neumorphic junction lighting only reads when
    /// the surfaces that meet are light. The dark-terminal looks are the dark
    /// faces in `NeoPanePresets`.
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
                "app.buttonTextOnAccent": "#FFFFFF",
                "neo.surface": "#E8EDF4",
                "neo.well": "#D8DEE8",
                "neo.shadowDark": "#A6B4C8",
                "neo.shadowLight": "#FFFFFF",
                "neo.accentShadow": "#5B7CFA",
            ]
        )
    }
}
