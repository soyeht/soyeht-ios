import SwiftUI
import UIKit
import SoyehtCore

enum SoyehtTheme {
    private static var appPalette: SoyehtAppPalette {
        TerminalColorTheme.active.appPalette
    }

    private static func color(_ hex: String) -> Color {
        Color(hex: hex)
    }

    private static func uiColor(_ hex: String) -> UIColor {
        let (red, green, blue) = ColorTheme.rgb8(from: hex)
        return UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    // MARK: - Backgrounds
    static var bgPrimary: Color { color(appPalette.backgroundHex) }
    static var bgSecondary: Color { color(appPalette.surfaceHex) }
    static var bgTertiary: Color { color(appPalette.surfaceRaisedHex) }
    static var bgKeybar: Color { color(appPalette.surfaceHex) }
    static var bgCard: Color { color(appPalette.cardHex) }
    static var bgCardBorder: Color { color(appPalette.borderHex) }

    // MARK: - Accent
    static var accentGreen: Color { color(appPalette.accentHex) }
    static var accentGreenDim: Color { color(appPalette.selectionHex) }
    static var accentAmber: Color { color(appPalette.warningHex) }
    static var accentRed: Color { color(appPalette.dangerHex) }
    static var accentInfo: Color { color(appPalette.infoHex) }
    static var accentLink: Color { color(appPalette.linkHex) }
    static var accentAlternate: Color { color(appPalette.alternateHex) }
    static var accentRedStrong: Color { color(appPalette.dangerStrongHex) }
    static var accentAmberStrong: Color { color(appPalette.warningStrongHex) }
    static var selection: Color { color(appPalette.selectionHex) }
    static var selectionText: Color { color(appPalette.selectionTextHex) }
    static var hover: Color { color(appPalette.hoverHex) }

    // MARK: - History Mode
    static var historyGreen: Color { color(appPalette.successHex) }
    static var historyGreenStrong: Color { color(appPalette.successStrongHex) }
    static var historyGreenBg: Color { color(appPalette.surfaceRaisedHex) }
    static var historyGreenBadge: Color { color(appPalette.selectionHex) }
    static var historyGray: Color { color(appPalette.readableSecondaryTextOnBackgroundHex) }
    static var historyControlsBg: Color { color(appPalette.surfaceHex) }
    static var historyToggleBg: Color { color(appPalette.surfaceRaisedHex) }
    static var historyHintBg: Color { color(appPalette.cardHex) }

    // MARK: - Pane States
    static var paneActiveBg: Color { color(appPalette.selectionHex) }
    static var paneActiveBorder: Color { color(appPalette.successStrongHex) }
    static var paneInactiveBg: Color { color(appPalette.cardHex) }
    static var paneInactiveBorder: Color { color(appPalette.borderHex) }

    // MARK: - Window Card
    static var windowCardBg: Color { color(appPalette.cardHex) }
    static var windowCardBorder: Color { color(appPalette.borderHex) }
    static var tabInactiveBorder: Color { color(appPalette.borderHex) }

    // MARK: - Overlay & Controls
    static var overlayBg: Color { color(appPalette.backgroundHex) }
    static var progressTrack: Color { color(appPalette.borderHex) }
    static var buttonTextOnAccent: Color { color(appPalette.buttonTextOnAccentHex) }

    // MARK: - Text
    static var textPrimary: Color { color(appPalette.textPrimaryHex) }
    static var textSecondary: Color { color(appPalette.textSecondaryHex) }
    static var textTertiary: Color { color(appPalette.readableSecondaryTextOnBackgroundHex) }
    static var textComment: Color { color(appPalette.readableSecondaryTextOnBackgroundHex) }
    static var textWarning: Color { color(appPalette.warningStrongHex) }

    // MARK: - Status
    static var statusOnline: Color { color(appPalette.successHex) }
    static var statusOffline: Color { color(appPalette.readableSecondaryTextOnBackgroundHex) }

    // MARK: - UIKit Colors
    static var uiBgPrimary: UIColor { uiColor(appPalette.backgroundHex) }
    static var uiBgCard: UIColor { uiColor(appPalette.cardHex) }
    static var uiBgKeybar: UIColor { uiColor(appPalette.surfaceHex) }
    static var uiAccentGreen: UIColor { uiColor(appPalette.accentHex) }
    static var uiTextPrimary: UIColor { uiColor(appPalette.textPrimaryHex) }
    static var uiTextSecondary: UIColor { uiColor(appPalette.textSecondaryHex) }
    static var uiButtonTextOnAccent: UIColor { uiColor(appPalette.buttonTextOnAccentHex) }

    // MARK: - Keybar Design Tokens
    static var uiBgKeybarFrame: UIColor { uiColor(appPalette.surfaceHex) }
    static var uiBgButton: UIColor { uiColor(appPalette.surfaceRaisedHex) }
    static var uiDivider: UIColor { uiColor(appPalette.borderHex) }
    static var uiTextButton: UIColor { uiColor(appPalette.textPrimaryHex) }
    static var uiTopBorder: UIColor { uiColor(appPalette.borderHex) }
    static var uiKillRed: UIColor { uiColor(appPalette.dangerHex) }
    static var uiBgKill: UIColor { uiColor(appPalette.surfaceHex) }
    static var uiEnterGreen: UIColor { uiColor(appPalette.successHex) }
    static var uiBgEnter: UIColor { uiColor(appPalette.surfaceHex) }
    static var uiScrollBtnBg: UIColor { uiColor(appPalette.surfaceRaisedHex) }
    static var uiScrollBtnBorder: UIColor { uiColor(appPalette.successHex) }

    // MARK: - Attachment Picker
    static var uiBgAttachmentPanel: UIColor { uiColor(appPalette.backgroundHex) }
    static var uiBgAttachmentCard: UIColor { uiColor(appPalette.cardHex) }
    static var uiAttachPhoto: UIColor { uiColor(appPalette.successHex) }
    static var uiAttachCamera: UIColor { uiColor(appPalette.linkHex) }
    static var uiAttachLocation: UIColor { uiColor(appPalette.dangerHex) }
    static var uiAttachDocument: UIColor { uiColor(appPalette.warningHex) }
    static var uiAttachFiles: UIColor { uiColor(appPalette.alternateHex) }

    static var preferredColorScheme: ColorScheme {
        appPalette.isDark ? .dark : .light
    }

    static var userInterfaceStyle: UIUserInterfaceStyle {
        appPalette.isDark ? .dark : .light
    }

    static var statusBarStyle: UIStatusBarStyle {
        appPalette.isDark ? .lightContent : .darkContent
    }

    // Typography tokens live in `SoyehtCore.Typography` — this file only holds
    // color tokens (SwiftUI Color + UIColor). Call sites use `Typography.mono*`
    // and `Typography.sans*` directly.
}

extension UIColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        var rgbValue: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgbValue) else { return nil }
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

// `Color.init(hex:)` lives in SoyehtCore (Extensions/Color+Hex.swift) — removed
// from here to avoid ambiguous use when both modules are imported in tests.
