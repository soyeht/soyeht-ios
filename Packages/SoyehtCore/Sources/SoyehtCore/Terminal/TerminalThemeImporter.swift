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
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var bold: String?
        var link: String?
        var extraHexColors: [String: String] = [:]
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
            case "cursor-text", "cursor_text", "cursor-text-color", "cursor_text_color":
                cursorText = firstValueToken(String(value))
            case "selection-background", "selection_background", "selection-color", "selection_color":
                selectionBackground = firstValueToken(String(value))
            case "selection-foreground", "selection_foreground", "selected-text-color", "selected_text_color":
                selectionForeground = firstValueToken(String(value))
            case "bold-color", "bold_color":
                bold = firstValueToken(String(value))
            case "link-color", "link_color":
                link = firstValueToken(String(value))
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
                recordExtraColorIfPresent(
                    key: key,
                    value: String(value),
                    into: &extraHexColors
                )
                continue
            }
        }

        return try makeTheme(
            filename: filename,
            sourceURL: sourceURL,
            background: background,
            foreground: foreground,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            bold: bold,
            link: link,
            ansi: ansi,
            extraHexColors: extraHexColors
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
        let cursorText = hexColor(from: dict["Cursor Text Color"])
        let selectionBackground = hexColor(from: dict["Selection Color"])
        let selectionForeground = hexColor(from: dict["Selected Text Color"])
        let bold = hexColor(from: dict["Bold Color"])
        let link = hexColor(from: dict["Link Color"])
        var extraHexColors: [String: String] = [:]
        var ansi = Array<String?>(repeating: nil, count: 16)

        for index in 0..<16 {
            ansi[index] = hexColor(from: dict["Ansi \(index) Color"])
        }

        let knownColorKeys = knownItermColorKeys()
        for (key, value) in dict where !knownColorKeys.contains(key) {
            guard let hex = hexColor(from: value) else { continue }
            let metadataKey = TerminalColorTheme.normalizedMetadataKey(key)
            guard !metadataKey.isEmpty else { continue }
            extraHexColors[metadataKey] = hex
        }

        return try makeTheme(
            filename: filename,
            sourceURL: sourceURL,
            background: background,
            foreground: foreground,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            bold: bold,
            link: link,
            ansi: ansi,
            extraHexColors: extraHexColors
        )
    }

    private static func makeTheme(
        filename: String?,
        sourceURL: String?,
        background: String?,
        foreground: String?,
        cursor: String?,
        cursorText: String?,
        selectionBackground: String?,
        selectionForeground: String?,
        bold: String?,
        link: String?,
        ansi: [String?],
        extraHexColors: [String: String]
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
            cursorTextHex: cursorText,
            selectionBackgroundHex: selectionBackground,
            selectionForegroundHex: selectionForeground,
            boldHex: bold,
            linkHex: link,
            ansiHex: ansi.compactMap { $0 },
            source: .imported,
            sourceURL: sourceURL,
            extraHexColors: extraHexColors
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

    private static func recordExtraColorIfPresent(
        key: String,
        value: String,
        into colors: inout [String: String]
    ) {
        guard isLikelyColorKey(key),
              let hex = TerminalColorTheme.normalizedHex(firstValueToken(value)) else {
            return
        }
        let metadataKey = TerminalColorTheme.normalizedMetadataKey(key)
        guard !metadataKey.isEmpty else { return }
        colors[metadataKey] = hex
    }

    private static func isLikelyColorKey(_ key: String) -> Bool {
        let normalized = TerminalColorTheme.normalizedMetadataKey(key)
        return normalized.contains("color")
            || normalized.contains("foreground")
            || normalized.contains("background")
            || normalized.contains("selection")
            || normalized.contains("cursor")
            || normalized.contains("link")
            || normalized.contains("bold")
    }

    private static func knownItermColorKeys() -> Set<String> {
        var keys: Set<String> = [
            "Background Color",
            "Foreground Color",
            "Cursor Color",
            "Cursor Text Color",
            "Selection Color",
            "Selected Text Color",
            "Bold Color",
            "Link Color",
        ]
        for index in 0..<16 {
            keys.insert("Ansi \(index) Color")
        }
        return keys
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
