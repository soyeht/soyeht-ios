import CoreGraphics
import Foundation

public enum TerminalThemeImporter {
    public static func importTheme(
        data: Data,
        filename: String? = nil,
        sourceURL: String? = nil
    ) throws -> TerminalColorTheme {
        if let theme = try? importItermColors(data: data, filename: filename, sourceURL: sourceURL) {
            return theme
        }
        if let text = String(data: data, encoding: .utf8),
           let theme = try? importGhostty(text: text, filename: filename, sourceURL: sourceURL) {
            return theme
        }
        throw TerminalThemeError.unsupportedFormat
    }

    public static func importGhostty(
        text: String,
        filename: String? = nil,
        sourceURL: String? = nil
    ) throws -> TerminalColorTheme {
        var background: String?
        var foreground: String?
        var cursor: String?
        var ansi = Array<String?>(repeating: nil, count: 16)

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "background":
                background = firstValueToken(String(value))
            case "foreground":
                foreground = firstValueToken(String(value))
            case "cursor-color", "cursor_color":
                cursor = firstValueToken(String(value))
            case "palette":
                let paletteValue = String(value)
                guard let paletteSeparator = paletteValue.firstIndex(of: "=") else { continue }
                let indexText = paletteValue[..<paletteSeparator]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let colorText = paletteValue[paletteValue.index(after: paletteSeparator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = Int(indexText), ansi.indices.contains(index) else { continue }
                ansi[index] = firstValueToken(String(colorText))
            default:
                continue
            }
        }

        return try makeTheme(
            filename: filename,
            sourceURL: sourceURL,
            background: background,
            foreground: foreground,
            cursor: cursor,
            ansi: ansi
        )
    }

    public static func importItermColors(
        data: Data,
        filename: String? = nil,
        sourceURL: String? = nil
    ) throws -> TerminalColorTheme {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw TerminalThemeError.unsupportedFormat
        }

        let background = hexColor(from: dict["Background Color"])
        let foreground = hexColor(from: dict["Foreground Color"])
        let cursor = hexColor(from: dict["Cursor Color"]) ?? foreground
        var ansi = Array<String?>(repeating: nil, count: 16)

        for index in 0..<16 {
            ansi[index] = hexColor(from: dict["Ansi \(index) Color"])
        }

        return try makeTheme(
            filename: filename,
            sourceURL: sourceURL,
            background: background,
            foreground: foreground,
            cursor: cursor,
            ansi: ansi
        )
    }

    private static func makeTheme(
        filename: String?,
        sourceURL: String?,
        background: String?,
        foreground: String?,
        cursor: String?,
        ansi: [String?]
    ) throws -> TerminalColorTheme {
        guard let background else { throw TerminalThemeError.missingRequiredColor("background") }
        guard let foreground else { throw TerminalThemeError.missingRequiredColor("foreground") }
        guard ansi.count == 16, ansi.allSatisfy({ $0 != nil }) else {
            throw TerminalThemeError.invalidAnsiColorCount(ansi.compactMap { $0 }.count)
        }

        let name = displayName(from: filename, sourceURL: sourceURL)
        let theme = TerminalColorTheme(
            id: TerminalColorTheme.slug(name),
            displayName: name,
            backgroundHex: background,
            foregroundHex: foreground,
            cursorHex: cursor ?? foreground,
            ansiHex: ansi.compactMap { $0 },
            source: .imported,
            sourceURL: sourceURL
        )
        return try theme.validated()
    }

    private static func displayName(from filename: String?, sourceURL: String?) -> String {
        let rawName: String
        if let filename, !filename.isEmpty {
            rawName = filename
        } else if let sourceURL,
                  let url = URL(string: sourceURL),
                  !url.lastPathComponent.isEmpty {
            rawName = url.lastPathComponent
        } else {
            rawName = "Imported Theme"
        }

        let base = (rawName as NSString).deletingPathExtension
        let decoded = base.removingPercentEncoding ?? base
        return decoded
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstValueToken(_ value: String) -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = token.range(of: " #") {
            token = String(token[..<comment.lowerBound])
        }
        if let first = token.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
            token = String(first)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hexColor(from value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        let red = component(dict["Red Component"])
        let green = component(dict["Green Component"])
        let blue = component(dict["Blue Component"])
        guard let red, let green, let blue else { return nil }
        return String(
            format: "#%02X%02X%02X",
            clamp8(red),
            clamp8(green),
            clamp8(blue)
        )
    }

    private static func component(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? CGFloat { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func clamp8(_ component: Double) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }
}
