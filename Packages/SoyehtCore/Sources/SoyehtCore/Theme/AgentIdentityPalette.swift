import Foundation

/// The colours that tell one agent's pane from another's: the plate its name
/// sits on in the pane header.
///
/// **No colour is created here, and none is chosen either.** A theme states
/// its plates or it has none, and a theme with none is a theme the
/// neomorphic style will not wear.
///
/// This file used to derive the plates from hues, lightness floors and
/// collision rules, mixing new colours out of a theme's accent. Six themes
/// carried none of their own, so every adjustment to that code silently
/// restyled them, including `neoMilk`, whose palette had been reviewed and
/// approved long before. Approved colour is data. Deriving it means an
/// implementation detail can overwrite a decision.
///
/// Nothing replaces it. The style that paints plates now only wears themes
/// that state them, so there is no gap left to fill.
public enum AgentIdentityPalette {
    /// The plates a theme shows, in order.
    ///
    /// A theme states them or it has none. There is no third case: only the
    /// neomorphic style paints a plate, and `DesignStyle.canWear` keeps that
    /// style off any theme that states none — so an empty result means the
    /// header draws no plate at all, which is what classic chrome does too.
    public static func plates(for theme: TerminalColorTheme) -> [String] {
        pinnedPlates(in: theme) ?? []
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
