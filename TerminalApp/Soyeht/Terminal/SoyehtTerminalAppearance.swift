import UIKit
import SoyehtCore
import SwiftTerm

enum SoyehtTerminalAppearance {

    static func apply(to terminalView: TerminalView) {
        let theme = TerminalColorTheme.active
        let cursorHex = TerminalColorTheme.normalizedHex(TerminalPreferences.shared.cursorColorHex) ?? theme.cursorHex

        terminalView.installColors(theme.palette)
        terminalView.isOpaque = true
        terminalView.backgroundColor = uiColor(theme.backgroundHex)
        terminalView.nativeForegroundColor = uiColor(theme.foregroundHex)
        terminalView.nativeBackgroundColor = uiColor(theme.backgroundHex)
        terminalView.caretColor = uiColor(cursorHex)
        terminalView.keyboardAppearance = .dark
        terminalView.allowMouseReporting = false

        let size = TerminalPreferences.shared.fontSize
        terminalView.setFonts(
            normal:     Typography.monoUIFont(size: size, weight: .regular, italic: false),
            bold:       Typography.monoUIFont(size: size, weight: .bold,    italic: false),
            italic:     Typography.monoUIFont(size: size, weight: .regular, italic: true),
            boldItalic: Typography.monoUIFont(size: size, weight: .bold,    italic: true)
        )

        if let style = CursorStyle.from(string: TerminalPreferences.shared.cursorStyle) {
            terminalView.getTerminal().setCursorStyle(style)
        }
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
}
