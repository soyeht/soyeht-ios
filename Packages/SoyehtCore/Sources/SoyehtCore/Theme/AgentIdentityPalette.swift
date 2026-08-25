import Foundation

/// The colours that tell one agent's pane from another's: the plate its name
/// sits on in the pane header.
///
/// **There is no derivation here, and there must never be one again.** Every
/// theme states its own colours as data, and a theme that states none gets the
/// fixed set below — the same for all of them, computed from nothing.
///
/// This file used to derive the plates per theme from hues, lightness floors
/// and collision rules. Six themes carried no colours of their own, so every
/// adjustment to that code silently restyled them, including `neoMilk`, whose
/// palette had been reviewed and approved long before. Approved colour is data.
/// Deriving it means an implementation detail can overwrite a decision.
public enum AgentIdentityPalette {
    /// Used only by a theme that pins nothing — an imported or user theme.
    /// Fixed, and identical for every such theme: no rule reads the theme's
    /// own colours, so nothing here can drift when a theme changes.
    public static let fallbackPlates: [String] = [
        "#4A3653", "#5B313A", "#2D4327", "#004641", "#3A4356",
    ]

    /// The plates a theme shows, in order.
    public static func plates(for theme: TerminalColorTheme) -> [String] {
        pinnedPlates(in: theme) ?? fallbackPlates
    }

    /// A theme's own colours, if it states them. Reads `agent.0`, `agent.1`, …
    /// for as many as are present: a theme may carry four or five, and neither
    /// count is converted into the other.
    public static func pinnedPlates(in theme: TerminalColorTheme) -> [String]? {
        var pinned: [String] = []
        var index = 0
        while let hex = theme.extraHexColors["agent.\(index)"] {
            pinned.append(hex)
            index += 1
        }
        return pinned.isEmpty ? nil : pinned
    }
}
