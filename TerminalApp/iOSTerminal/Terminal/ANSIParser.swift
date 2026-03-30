import SwiftUI

// MARK: - ANSI Escape Code Parser

enum ANSIParser {
    private typealias SColor = SwiftUI.Color

    static func parse(_ text: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        var fg: SColor = .white
        var bold = false
        var buffer = ""

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1b}" {
                // Flush buffer
                if !buffer.isEmpty {
                    result.append(styled(buffer, fg: fg, bold: bold, fontSize: fontSize))
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
                        applySGR(paramStr, fg: &fg, bold: &bold)
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
        if !buffer.isEmpty { result.append(styled(buffer, fg: fg, bold: bold, fontSize: fontSize)) }
        return result
    }

    private static func styled(_ text: String, fg: SColor, bold: Bool, fontSize: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = fg
        attr.font = .system(size: fontSize, weight: bold ? .bold : .regular, design: .monospaced)
        return attr
    }

    private static func applySGR(_ params: String, fg: inout SColor, bold: inout Bool) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        if codes.isEmpty { fg = .white; bold = false; return }

        var idx = 0
        while idx < codes.count {
            let c = codes[idx]
            switch c {
            case 0: fg = .white; bold = false
            case 1: bold = true
            case 2, 22: bold = false
            case 30...37: fg = color8(c - 30)
            case 39: fg = .white
            case 90...97: fg = colorBright(c - 90)
            case 38:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    fg = color256(codes[idx + 2]); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    fg = SColor(red: Double(codes[idx+2])/255, green: Double(codes[idx+3])/255, blue: Double(codes[idx+4])/255)
                    idx += 4
                }
            default: break
            }
            idx += 1
        }
    }

    private static func color8(_ i: Int) -> SColor {
        [SColor(red: 0, green: 0, blue: 0),
         SColor(red: 0.8, green: 0.2, blue: 0.2),
         SColor(red: 0.2, green: 0.8, blue: 0.2),
         SColor(red: 0.8, green: 0.8, blue: 0.2),
         SColor(red: 0.3, green: 0.3, blue: 0.9),
         SColor(red: 0.8, green: 0.2, blue: 0.8),
         SColor(red: 0.2, green: 0.8, blue: 0.8),
         SColor(red: 0.75, green: 0.75, blue: 0.75)][min(i, 7)]
    }

    private static func colorBright(_ i: Int) -> SColor {
        [SColor(white: 0.5),
         SColor(red: 1, green: 0.33, blue: 0.33),
         SColor(red: 0.33, green: 1, blue: 0.33),
         SColor(red: 1, green: 1, blue: 0.33),
         SColor(red: 0.4, green: 0.4, blue: 1),
         SColor(red: 1, green: 0.33, blue: 1),
         SColor(red: 0.33, green: 1, blue: 1),
         .white][min(i, 7)]
    }

    private static func color256(_ i: Int) -> SColor {
        if i < 8 { return color8(i) }
        if i < 16 { return colorBright(i - 8) }
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
