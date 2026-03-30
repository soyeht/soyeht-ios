import UIKit
import SwiftTerm

enum SoyehtTerminalAppearance {

    // MARK: - 16-Color ANSI Palette

    private static func c8(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    static let palette: [SwiftTerm.Color] = [
        c8(0,   0,   0),       // 0  black
        c8(239, 68,  68),      // 1  red       (#EF4444)
        c8(0,   217, 163),     // 2  green     (#00D9A3)
        c8(245, 158, 11),      // 3  yellow    (#F59E0B)
        c8(3,   0,   178),     // 4  blue
        c8(178, 0,   178),     // 5  magenta
        c8(0,   165, 178),     // 6  cyan
        c8(229, 229, 229),     // 7  white
        c8(102, 102, 102),     // 8  bright black (#666666)
        c8(239, 68,  68),      // 9  bright red
        c8(0,   217, 163),     // 10 bright green (#00D9A3)
        c8(255, 170, 0),       // 11 bright yellow (#FFAA00)
        c8(7,   0,   254),     // 12 bright blue
        c8(229, 0,   229),     // 13 bright magenta
        c8(0,   229, 229),     // 14 bright cyan
        c8(255, 255, 255),     // 15 bright white
    ]

    // MARK: - Apply Appearance

    static func apply(to terminalView: TerminalView) {
        terminalView.installColors(palette)
        terminalView.isOpaque = true
        terminalView.backgroundColor = SoyehtTheme.uiBgPrimary
        terminalView.nativeForegroundColor = SoyehtTheme.uiTextPrimary
        terminalView.nativeBackgroundColor = SoyehtTheme.uiBgPrimary
        terminalView.caretColor = UIColor(hex: TerminalPreferences.shared.cursorColorHex)
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
