import UIKit
import SwiftTerm

// Converts a SwiftTerm `BufferLine` (cells with ANSI attributes) into an
// `NSAttributedString` styled with the active `ColorTheme` palette.
//
// Consecutive cells sharing the same `Attribute` are coalesced into a single
// attributed run for O(runs) string building instead of O(cells).
enum AnsiAttributedStringBuilder {

    static func build(
        line: BufferLine,
        theme: ColorTheme,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let trimmed = line.getTrimmedLength()
        guard trimmed > 0 else { return NSAttributedString() }

        let output = NSMutableAttributedString()
        var runText = ""
        var runAttribute: Attribute? = nil

        var col = 0
        while col < trimmed {
            let cell = line[col]
            let character = cell.getCharacter()
            // Skip the trailing null cell that SwiftTerm writes after a wide (width == 2) character.
            if col > 0 && character == "\0" && line[col - 1].width == 2 {
                col += 1
                continue
            }
            if let current = runAttribute, current != cell.attribute {
                output.append(makeRun(text: runText, attribute: current, theme: theme, fontSize: fontSize))
                runText = ""
            }
            runAttribute = cell.attribute
            runText.append(character)
            col += 1
        }
        if !runText.isEmpty, let last = runAttribute {
            output.append(makeRun(text: runText, attribute: last, theme: theme, fontSize: fontSize))
        }
        return output
    }

    private static func makeRun(
        text: String,
        attribute: Attribute,
        theme: ColorTheme,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let style = attribute.style
        let inverse = style.contains(.inverse)
        let dim = style.contains(.dim)
        let underline = style.contains(.underline)
        let crossedOut = style.contains(.crossedOut)
        let invisible = style.contains(.invisible)

        var fg = resolve(color: attribute.fg, theme: theme, role: .foreground)
        var bg = resolve(color: attribute.bg, theme: theme, role: .background)
        if inverse { swap(&fg, &bg) }
        if dim { fg = fg.withAlphaComponent(0.6) }
        if invisible { fg = bg }

        let font = monospacedFont(
            size: fontSize,
            bold: style.contains(.bold),
            italic: style.contains(.italic)
        )

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg
        ]

        let showsBackground = inverse
            || (attribute.bg != .defaultColor && attribute.bg != .defaultInvertedColor)
        if showsBackground {
            attrs[.backgroundColor] = bg
        }

        if underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let colorValue = attribute.underlineColor {
                attrs[.underlineColor] = resolve(color: colorValue, theme: theme, role: .foreground)
            }
        }

        if crossedOut {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return NSAttributedString(string: text, attributes: attrs)
    }

    private enum ColorRole { case foreground, background }

    private static func resolve(
        color: Attribute.Color,
        theme: ColorTheme,
        role: ColorRole
    ) -> UIColor {
        switch color {
        case .defaultColor:
            let hex = (role == .foreground) ? theme.foregroundHex : theme.backgroundHex
            return UIColor(hex: hex) ?? (role == .foreground ? .white : .black)
        case .defaultInvertedColor:
            let hex = (role == .foreground) ? theme.backgroundHex : theme.foregroundHex
            return UIColor(hex: hex) ?? (role == .foreground ? .black : .white)
        case .ansi256(let code):
            return ansi256(Int(code), theme: theme)
        case .trueColor(let r, let g, let b):
            return UIColor(
                red: CGFloat(r) / 255,
                green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255,
                alpha: 1
            )
        }
    }

    private static func ansi256(_ index: Int, theme: ColorTheme) -> UIColor {
        if index < 16 {
            return UIColor(hex: theme.ansiHex[index]) ?? .white
        }
        if index < 232 {
            let adj = index - 16
            let r = adj / 36
            let g = (adj % 36) / 6
            let b = adj % 6
            return UIColor(
                red: r == 0 ? 0 : CGFloat(r * 40 + 55) / 255,
                green: g == 0 ? 0 : CGFloat(g * 40 + 55) / 255,
                blue: b == 0 ? 0 : CGFloat(b * 40 + 55) / 255,
                alpha: 1
            )
        }
        let gray = CGFloat((index - 232) * 10 + 8) / 255
        return UIColor(white: gray, alpha: 1)
    }

    private static func monospacedFont(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let weight: UIFont.Weight = bold ? .semibold : .regular
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        if let desc = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: desc, size: size)
        }
        return base
    }
}
