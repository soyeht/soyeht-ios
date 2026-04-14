import UIKit

// Converts a raw terminal string (possibly containing ANSI CSI escape codes)
// into one `NSAttributedString` per line. Mirrors the SwiftUI `ANSIParser`
// but outputs UIKit attributes so it can feed `UICollectionView` cells.
//
// Handles SGR only — the subset produced by tmux capture-pane output:
// reset, bold, 8/16 fg/bg, 256-color, truecolor. Unknown sequences are
// stripped silently.
enum AnsiTextParser {

    static func parseLines(
        _ text: String,
        fontSize: CGFloat,
        theme: ColorTheme
    ) -> [NSAttributedString] {
        var lines: [NSAttributedString] = []
        var current = NSMutableAttributedString()
        var fg = UIColor(hex: theme.foregroundHex) ?? .white
        var bg: UIColor? = nil
        var bold = false
        var buffer = ""

        let defaultFg = UIColor(hex: theme.foregroundHex) ?? .white

        func flush() {
            if buffer.isEmpty { return }
            current.append(styled(buffer, fg: fg, bg: bg, bold: bold, fontSize: fontSize))
            buffer = ""
        }

        func endLine() {
            flush()
            lines.append(NSAttributedString(attributedString: current))
            current = NSMutableAttributedString()
        }

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\n" {
                endLine()
                i = text.index(after: i)
                continue
            }
            if ch == "\r" {
                // Treat lone CR as soft reset to start of line.
                flush()
                current = NSMutableAttributedString()
                i = text.index(after: i)
                continue
            }
            if ch == "\u{1b}" {
                flush()
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "[" {
                    var paramStr = ""
                    var j = text.index(after: next)
                    while j < text.endIndex && (text[j].isNumber || text[j] == ";") {
                        paramStr.append(text[j])
                        j = text.index(after: j)
                    }
                    if j < text.endIndex && text[j] == "m" {
                        applySGR(paramStr, fg: &fg, bg: &bg, bold: &bold, theme: theme, defaultFg: defaultFg)
                        i = text.index(after: j)
                        continue
                    }
                    if j < text.endIndex && text[j].isLetter {
                        // Unknown CSI — skip it.
                        i = text.index(after: j)
                        continue
                    }
                }
                i = text.index(after: i)
                continue
            }
            buffer.append(ch)
            i = text.index(after: i)
        }
        endLine()

        // Drop trailing empty line added by the final endLine after the last \n.
        if let last = lines.last, last.length == 0 { lines.removeLast() }

        return lines
    }

    // MARK: - SGR

    private static func styled(
        _ text: String,
        fg: UIColor,
        bg: UIColor?,
        bold: Bool,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let weight: UIFont.Weight = bold ? .semibold : .regular
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: fg
        ]
        if let bg { attrs[.backgroundColor] = bg }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func applySGR(
        _ params: String,
        fg: inout UIColor,
        bg: inout UIColor?,
        bold: inout Bool,
        theme: ColorTheme,
        defaultFg: UIColor
    ) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        if codes.isEmpty { fg = defaultFg; bg = nil; bold = false; return }

        var idx = 0
        while idx < codes.count {
            let c = codes[idx]
            switch c {
            case 0: fg = defaultFg; bg = nil; bold = false
            case 1: bold = true
            case 2, 22: bold = false
            case 30...37: fg = color8(c - 30, theme: theme)
            case 39: fg = defaultFg
            case 90...97: fg = colorBright(c - 90, theme: theme)
            case 38:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    fg = color256(codes[idx + 2], theme: theme); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    fg = UIColor(
                        red: CGFloat(codes[idx + 2]) / 255,
                        green: CGFloat(codes[idx + 3]) / 255,
                        blue: CGFloat(codes[idx + 4]) / 255,
                        alpha: 1
                    )
                    idx += 4
                }
            case 40...47: bg = color8(c - 40, theme: theme)
            case 49: bg = nil
            case 100...107: bg = colorBright(c - 100, theme: theme)
            case 48:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    bg = color256(codes[idx + 2], theme: theme); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    bg = UIColor(
                        red: CGFloat(codes[idx + 2]) / 255,
                        green: CGFloat(codes[idx + 3]) / 255,
                        blue: CGFloat(codes[idx + 4]) / 255,
                        alpha: 1
                    )
                    idx += 4
                }
            default: break
            }
            idx += 1
        }
    }

    private static func color8(_ i: Int, theme: ColorTheme) -> UIColor {
        UIColor(hex: theme.ansiHex[min(i, 7)]) ?? .white
    }

    private static func colorBright(_ i: Int, theme: ColorTheme) -> UIColor {
        UIColor(hex: theme.ansiHex[min(i + 8, 15)]) ?? .white
    }

    private static func color256(_ i: Int, theme: ColorTheme) -> UIColor {
        if i < 16 { return UIColor(hex: theme.ansiHex[i]) ?? .white }
        if i < 232 {
            let adj = i - 16
            let r = adj / 36, g = (adj % 36) / 6, b = adj % 6
            return UIColor(
                red: r == 0 ? 0 : CGFloat(r * 40 + 55) / 255,
                green: g == 0 ? 0 : CGFloat(g * 40 + 55) / 255,
                blue: b == 0 ? 0 : CGFloat(b * 40 + 55) / 255,
                alpha: 1
            )
        }
        let gray = CGFloat((i - 232) * 10 + 8) / 255
        return UIColor(white: gray, alpha: 1)
    }
}
