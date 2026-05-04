import SwiftUI
import SoyehtCore

/// SwiftUI color tokens consumed by the macOS Claw Store views. Values
/// are duplicated from the iOS SoyehtTheme hex codes so the two targets
/// render the same surface shades without either depending on the
/// other's theme file.
enum MacClawStoreTheme {
    private static var appPalette: SoyehtAppPalette {
        TerminalColorTheme.active.appPalette
    }

    static var bgPrimary: Color { Color(hex: appPalette.backgroundHex) }
    static var bgCard: Color { Color(hex: appPalette.cardHex) }
    static var bgCardBorder: Color { Color(hex: appPalette.borderHex) }
    static var readableStroke: Color { Color(hex: appPalette.readableSecondaryTextOnBackgroundHex) }
    static var bgRowHover: Color { Color(hex: appPalette.hoverHex) }

    static var accentGreen: Color { Color(hex: appPalette.accentHex) }
    static var accentAmber: Color { Color(hex: appPalette.warningHex) }
    static var statusGreen: Color { Color(hex: appPalette.successHex) }
    static var statusGreenBg: Color { Color(hex: appPalette.selectionHex) }
    static var statusGreenStrong: Color { Color(hex: appPalette.successStrongHex) }

    static var textPrimary: Color { Color(hex: appPalette.readableTextOnBackgroundHex) }
    static var textSecondary: Color { Color(hex: appPalette.readableSecondaryTextOnBackgroundHex) }
    static var textMuted: Color { Color(hex: appPalette.readableSecondaryTextOnBackgroundHex) }
    static var textWarning: Color { Color(hex: appPalette.warningStrongHex) }
    static var textComment: Color { Color(hex: appPalette.readableSecondaryTextOnBackgroundHex) }
    static var buttonTextOnAccent: Color { Color(hex: appPalette.buttonTextOnAccentHex) }

    static var preferredColorScheme: ColorScheme {
        appPalette.isDark ? .dark : .light
    }
}
