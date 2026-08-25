import Foundation

/// A visual design style for app chrome — shape, elevation, borders and
/// chrome typography.
///
/// Classic wears any terminal colour theme. Neomorphic does NOT: it needs
/// roles no ordinary theme carries — a raised surface, a recess, two shadow
/// pairs, an agent plate per pane — and it only wears the themes that state
/// them. Nothing computes those roles for a theme that lacks them.
///
/// It used to wear anything, filling the gaps by derivation, and that is the
/// whole of what went wrong: every revision of the derivation restyled the
/// themes relying on it, and the fixed values that replaced the derivation
/// were dark, so a light imported theme rendered near-black chrome with its
/// own text on it at 1.29:1 and the agent's name at 1.02:1.
///
/// Terminal glyph content is never restyled: the grid keeps JetBrains Mono
/// and the theme's ANSI colors regardless of style.
public enum DesignStyle: String, CaseIterable, Codable, Sendable {
    case classic
    case neomorphic
    case neubrutalist

    /// Styles selectable in Settings. Only styles fully shipped in this
    /// build are listed; the picker stays hidden while there is just one.
    public static var available: [DesignStyle] { [.classic, .neomorphic] }

    /// Whether this style can wear a given colour theme.
    ///
    /// Classic can wear anything. Neomorphic wears only a theme that states
    /// every role it paints — which is a property of the theme, checked
    /// against the theme, not a list of ids to keep in sync.
    public func canWear(_ theme: TerminalColorTheme) -> Bool {
        switch self {
        case .classic, .neubrutalist:
            return true
        case .neomorphic:
            return Self.neomorphicRoles.allSatisfy { theme.extraHexColors[$0] != nil }
        }
    }

    /// The roles neomorphic chrome paints and cannot invent. The four agent
    /// plates are in here for the same reason as the rest: the pane header IS
    /// a plate under this style, and a theme stating none leaves the header
    /// nothing to paint — it indexed an empty array and trapped. A fifth
    /// plate is optional; the eight pane faces carry one and neoMilk does not.
    static let neomorphicRoles = [
        "neo.surface", "neo.well", "neo.shadowDark", "neo.shadowLight",
        "neo.wellShadow", "neo.wellRim", "neo.accentShadow",
        "app.background", "app.surface", "app.accent",
        "app.textPrimary", "app.textSecondary", "app.textMuted",
        "agent.0", "agent.1", "agent.2", "agent.3",
    ]

    /// The persisted style, validated against `available` so a build that
    /// no longer ships a style falls back to classic instead of rendering
    /// half-implemented chrome — and against the active theme, so a style
    /// never paints a role the theme does not state.
    public static var active: DesignStyle {
        guard let raw = TerminalPreferences.shared.designStyleRaw,
              let style = DesignStyle(rawValue: raw),
              available.contains(style),
              style.canWear(TerminalColorTheme.active) else {
            return .classic
        }
        return style
    }

    /// The themes this style can wear, for a picker to offer.
    public static func themes(for style: DesignStyle, from all: [TerminalColorTheme]) -> [TerminalColorTheme] {
        all.filter { style.canWear($0) }
    }

    /// Persist a style choice. Callers are responsible for posting their
    /// platform's preferences-changed notification afterwards.
    public static func setActive(_ style: DesignStyle) {
        TerminalPreferences.shared.designStyleRaw = style.rawValue
    }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .neomorphic: return "Neomorphic"
        case .neubrutalist: return "Neubrutalist"
        }
    }
}
