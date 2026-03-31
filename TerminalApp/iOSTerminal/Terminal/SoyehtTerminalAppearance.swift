import UIKit
import SwiftTerm

enum SoyehtTerminalAppearance {

    static func apply(to terminalView: TerminalView) {
        let theme = ColorTheme.active

        terminalView.installColors(theme.palette)
        terminalView.isOpaque = true
        terminalView.backgroundColor = UIColor(hex: theme.backgroundHex) ?? .black
        terminalView.nativeForegroundColor = UIColor(hex: theme.foregroundHex) ?? .white
        terminalView.nativeBackgroundColor = UIColor(hex: theme.backgroundHex) ?? .black
        terminalView.caretColor = UIColor(hex: TerminalPreferences.shared.cursorColorHex)
            ?? UIColor(hex: theme.defaultCursorHex)
            ?? SoyehtTheme.uiAccentGreen
        terminalView.keyboardAppearance = .dark
        terminalView.allowMouseReporting = false

        let fontSize = TerminalPreferences.shared.fontSize
        terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if let style = CursorStyle.from(string: TerminalPreferences.shared.cursorStyle) {
            terminalView.getTerminal().setCursorStyle(style)
        }
    }
}
