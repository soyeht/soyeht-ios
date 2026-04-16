import SwiftUI
import SoyehtCore

// MARK: - ANSI Escape Code Parser

enum ANSIParser {
    private typealias SColor = SwiftUI.Color

    static func parse(_ text: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        let theme = ColorTheme.active
        var fg: SColor = SColor(hex: theme.foregroundHex)
        var bg: SColor? = nil
        var bold = false
        var italic = false
        var buffer = ""

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1b}" {
                // Flush buffer
                if !buffer.isEmpty {
                    result.append(styled(buffer, fg: fg, bg: bg, bold: bold, italic: italic, fontSize: fontSize))
                    buffer = ""
                }
                // Try to parse CSI: ESC [ params m
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "[" {
                    var paramStr = ""
                    var j = text.index(after: next)
                    while j < text.endIndex && (text[j].isNumber || text[j] == ";") {
                        paramStr.append(text[j])
                        j = text.index(after: j)
                    }
                    if j < text.endIndex && text[j] == "m" {
                        applySGR(paramStr, fg: &fg, bg: &bg, bold: &bold, italic: &italic, theme: theme)
                        i = text.index(after: j)
                        continue
                    }
                    // Skip unrecognized CSI sequences
                    if j < text.endIndex && text[j].isLetter {
                        i = text.index(after: j)
                        continue
                    }
                }
                i = text.index(after: i)
            } else {
                buffer.append(text[i])
                i = text.index(after: i)
            }
        }
        if !buffer.isEmpty { result.append(styled(buffer, fg: fg, bg: bg, bold: bold, italic: italic, fontSize: fontSize)) }
        return result
    }

    private static func styled(_ text: String, fg: SColor, bg: SColor?, bold: Bool, italic: Bool, fontSize: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = fg
        if let bg { attr.backgroundColor = bg }
        attr.font = Typography.mono(size: fontSize, weight: bold ? .bold : .regular, italic: italic)
        return attr
    }

    private static func applySGR(_ params: String, fg: inout SColor, bg: inout SColor?, bold: inout Bool, italic: inout Bool, theme: ColorTheme) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        let defaultFg = SColor(hex: theme.foregroundHex)
        if codes.isEmpty { fg = defaultFg; bg = nil; bold = false; italic = false; return }

        var idx = 0
        while idx < codes.count {
            let c = codes[idx]
            switch c {
            case 0: fg = defaultFg; bg = nil; bold = false; italic = false
            case 1: bold = true
            case 2, 22: bold = false
            case 3: italic = true
            case 23: italic = false

            // Foreground
            case 30...37: fg = color8(c - 30, theme: theme)
            case 39: fg = defaultFg
            case 90...97: fg = colorBright(c - 90, theme: theme)
            case 38:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    fg = color256(codes[idx + 2], theme: theme); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    fg = SColor(red: Double(codes[idx+2])/255, green: Double(codes[idx+3])/255, blue: Double(codes[idx+4])/255)
                    idx += 4
                }

            // Background
            case 40...47: bg = color8(c - 40, theme: theme)
            case 49: bg = nil
            case 100...107: bg = colorBright(c - 100, theme: theme)
            case 48:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    bg = color256(codes[idx + 2], theme: theme); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    bg = SColor(red: Double(codes[idx+2])/255, green: Double(codes[idx+3])/255, blue: Double(codes[idx+4])/255)
                    idx += 4
                }

            default: break
            }
            idx += 1
        }
    }

    private static func color8(_ i: Int, theme: ColorTheme) -> SColor {
        theme.swiftUIPalette[min(i, 7)]
    }

    private static func colorBright(_ i: Int, theme: ColorTheme) -> SColor {
        theme.swiftUIPalette[min(i + 8, 15)]
    }

    private static func color256(_ i: Int, theme: ColorTheme) -> SColor {
        if i < 8 { return color8(i, theme: theme) }
        if i < 16 { return colorBright(i - 8, theme: theme) }
        if i < 232 {
            let adj = i - 16
            let r = adj / 36, g = (adj % 36) / 6, b = adj % 6
            return SColor(
                red: r == 0 ? 0 : Double(r * 40 + 55) / 255,
                green: g == 0 ? 0 : Double(g * 40 + 55) / 255,
                blue: b == 0 ? 0 : Double(b * 40 + 55) / 255)
        }
        let gray = Double((i - 232) * 10 + 8) / 255
        return SColor(white: gray)
    }
}
