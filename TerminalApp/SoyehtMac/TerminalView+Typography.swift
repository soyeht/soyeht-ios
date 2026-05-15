import AppKit
import SwiftTerm
import SoyehtCore

extension TerminalView {

    /// Sets the terminal's 4 font variants (normal/bold/italic/boldItalic) to
    /// JetBrains Mono at the given point size. Uses `setFonts(...)` so that
    /// italic/bold-italic cells render with the real `JetBrainsMono-Italic.ttf`
    /// and `-BoldItalic.ttf` glyphs — not slant-synthesized versions.
    func applyJetBrainsMono(size: CGFloat) {
        setFonts(
            normal:     Typography.monoNSFont(size: size, weight: .regular, italic: false),
            bold:       Typography.monoNSFont(size: size, weight: .bold,    italic: false),
            italic:     Typography.monoNSFont(size: size, weight: .regular, italic: true),
            boldItalic: Typography.monoNSFont(size: size, weight: .bold,    italic: true)
        )
    }

    func applySoyehtTerminalAppearance() {
        let theme = TerminalColorTheme.active
        let cursorHex = TerminalColorTheme.normalizedHex(TerminalPreferences.shared.cursorColorHex) ?? theme.cursorHex
        installColors(theme.palette)
        nativeForegroundColor = NSColor(soyehtRequiredHex: theme.foregroundHex)
        nativeBackgroundColor = NSColor(soyehtRequiredHex: theme.backgroundHex)
        caretColor = NSColor(soyehtRequiredHex: cursorHex)
        caretTextColor = NSColor(soyehtRequiredHex: theme.cursorTextHex ?? theme.backgroundHex)
        selectedTextBackgroundColor = NSColor(soyehtRequiredHex: theme.selectionBackgroundHex ?? theme.cursorHex)
        wantsLayer = true
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        applyJetBrainsMono(size: TerminalPreferences.shared.fontSize)
    }
}

extension NSColor {
    convenience init(soyehtRequiredHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }

    convenience init?(soyehtHex hex: String) {
        guard let normalized = TerminalColorTheme.normalizedHex(hex) else { return nil }
        let (r, g, b) = ColorTheme.rgb8(from: normalized)
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
