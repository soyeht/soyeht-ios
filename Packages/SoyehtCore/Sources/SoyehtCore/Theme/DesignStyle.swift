import Foundation

/// A visual design style for app chrome — shape, elevation, borders and
/// chrome typography. Orthogonal to the color theme: any terminal color
/// theme can be worn by any style, and styles derive their extra color
/// roles from the active `SoyehtAppPalette` (plus curated preset slots in
/// `TerminalColorTheme.extraHexColors` when present).
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

    /// The persisted style, validated against `available` so a build that
    /// no longer ships a style falls back to classic instead of rendering
    /// half-implemented chrome.
    public static var active: DesignStyle {
        guard let raw = TerminalPreferences.shared.designStyleRaw,
              let style = DesignStyle(rawValue: raw),
              available.contains(style) else {
            return .classic
        }
        return style
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
