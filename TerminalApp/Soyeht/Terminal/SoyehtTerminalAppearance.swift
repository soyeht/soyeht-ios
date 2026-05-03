import UIKit
import SoyehtCore
import SwiftTerm

enum SoyehtTerminalAppearance {

    static func apply(to terminalView: TerminalView) {
        let theme = TerminalColorTheme.active

        terminalView.installColors(theme.palette)
        terminalView.isOpaque = true
        terminalView.backgroundColor = UIColor(hex: theme.backgroundHex) ?? .black
        terminalView.nativeForegroundColor = UIColor(hex: theme.foregroundHex) ?? .white
        terminalView.nativeBackgroundColor = UIColor(hex: theme.backgroundHex) ?? .black
        terminalView.caretColor = UIColor(hex: TerminalPreferences.shared.cursorColorHex)
            ?? UIColor(hex: theme.cursorHex)
            ?? SoyehtTheme.uiAccentGreen
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
}
