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
}
