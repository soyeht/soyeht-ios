import SwiftUI

/// Cross-platform color tokens shared by all targets — iOS app, macOS app,
/// and the SoyehtLiveActivity widget. Values are derived from the active
/// terminal theme's app palette. SwiftUI `Color` so every target consumes them
/// directly; platform-specific UIColor/NSColor tokens live in each target's
/// theme file (`SoyehtTheme.swift`, `MacTheme.swift`).
public enum BrandColors {
    private static var appPalette: SoyehtAppPalette {
        TerminalColorTheme.active.appPalette
    }

    /// Primary app accent. Derived from the active terminal theme cursor color.
    public static var accentGreen: Color { Color(hex: appPalette.accentHex) }

    /// Warning / pending accent. Derived from ANSI yellow.
    public static var accentAmber: Color { Color(hex: appPalette.warningHex) }

    public static var accentAmberStrong: Color { Color(hex: appPalette.warningStrongHex) }
    public static var accentRed: Color { Color(hex: appPalette.dangerHex) }
    public static var accentGreenStrong: Color { Color(hex: appPalette.successStrongHex) }
    public static var selection: Color { Color(hex: appPalette.selectionHex) }
    public static var selectionText: Color { Color(hex: appPalette.selectionTextHex) }
    public static var hover: Color { Color(hex: appPalette.hoverHex) }

    /// Base surface. Derived from the active terminal background.
    public static var surfaceDeep: Color { Color(hex: appPalette.backgroundHex) }

    public static var surface: Color { Color(hex: appPalette.surfaceHex) }
    public static var surfaceRaised: Color { Color(hex: appPalette.surfaceRaisedHex) }
    public static var card: Color { Color(hex: appPalette.cardHex) }
    public static var border: Color { Color(hex: appPalette.borderHex) }

    public static var textPrimary: Color { Color(hex: appPalette.textPrimaryHex) }
    public static var textSecondary: Color { Color(hex: appPalette.textSecondaryHex) }

    /// Muted text. Derived from bright black / ANSI 8.
    public static var textMuted: Color { Color(hex: appPalette.textMutedHex) }

    public static var buttonTextOnAccent: Color { Color(hex: appPalette.buttonTextOnAccentHex) }

    public static var preferredColorScheme: ColorScheme {
        appPalette.isDark ? .dark : .light
    }
}
