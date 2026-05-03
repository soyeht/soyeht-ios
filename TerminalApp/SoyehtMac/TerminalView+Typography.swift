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
        installColors(theme.palette)
        nativeForegroundColor = NSColor(soyehtHex: theme.foregroundHex) ?? .white
        nativeBackgroundColor = NSColor(soyehtHex: theme.backgroundHex) ?? .black
        caretColor = NSColor(soyehtHex: TerminalPreferences.shared.cursorColorHex)
            ?? NSColor(soyehtHex: theme.cursorHex)
            ?? MacTheme.accentGreenEmerald
        wantsLayer = true
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        applyJetBrainsMono(size: TerminalPreferences.shared.fontSize)
    }
}

extension NSColor {
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
