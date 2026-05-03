import Foundation
import SwiftUI

public enum TerminalThemeError: Error, LocalizedError {
    case invalidHex(String)
    case invalidAnsiColorCount(Int)
    case missingRequiredColor(String)
    case unsupportedFormat
    case invalidTheme(String)
    case invalidCatalogResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHex(let value):
            return "Invalid hex color: \(value)"
        case .invalidAnsiColorCount(let count):
            return "Terminal themes must define exactly 16 ANSI colors; found \(count)."
        case .missingRequiredColor(let name):
            return "Missing required theme color: \(name)"
        case .unsupportedFormat:
            return "Unsupported terminal theme format."
        case .invalidTheme(let reason):
            return reason
        case .invalidCatalogResponse(let reason):
            return reason
        }
    }
}

public struct TerminalColorTheme: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case builtIn
        case imported
        case custom
    }

    public var id: String
    public var displayName: String
    public var backgroundHex: String
    public var foregroundHex: String
    public var cursorHex: String
    public var ansiHex: [String]
    public var source: Source
    public var sourceURL: String?

    public init(
        id: String,
        displayName: String,
        backgroundHex: String,
        foregroundHex: String,
        cursorHex: String,
        ansiHex: [String],
        source: Source,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.cursorHex = cursorHex
        self.ansiHex = ansiHex
        self.source = source
        self.sourceURL = sourceURL
    }

    public static var active: TerminalColorTheme {
        TerminalThemeStore.shared.activeTheme
    }

    public static var builtInThemes: [TerminalColorTheme] {
        ColorTheme.allCases.map(\.terminalTheme)
    }

    public var defaultCursorHex: String {
        cursorHex
    }

    public var swiftUIPalette: [SwiftUI.Color] {
        ansiHex.map { SwiftUI.Color(hex: $0) }
    }

    public var previewSwatches: [SwiftUI.Color] {
        guard swiftUIPalette.count >= 7 else { return [] }
        return [swiftUIPalette[2], swiftUIPalette[6], swiftUIPalette[3], swiftUIPalette[1]]
    }

    public func validated() throws -> TerminalColorTheme {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TerminalThemeError.invalidTheme("Theme name cannot be empty.")
        }
        guard ansiHex.count == 16 else {
            throw TerminalThemeError.invalidAnsiColorCount(ansiHex.count)
        }

        var copy = self
        copy.id = Self.slug(copy.id.isEmpty ? copy.displayName : copy.id)
        copy.displayName = copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.backgroundHex = try Self.requireHex(copy.backgroundHex)
        copy.foregroundHex = try Self.requireHex(copy.foregroundHex)
        copy.cursorHex = try Self.requireHex(copy.cursorHex)
        copy.ansiHex = try copy.ansiHex.map(Self.requireHex)
        return copy
    }

    public static func requireHex(_ value: String) throws -> String {
        guard let normalized = normalizedHex(value) else {
            throw TerminalThemeError.invalidHex(value)
        }
        return normalized
    }

    public static func normalizedHex(_ value: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            raw.removeFirst()
            raw.removeLast()
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            raw.removeFirst()
            raw.removeLast()
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        if raw.count == 8 {
            raw = String(raw.prefix(6))
        }
        guard raw.count == 6 else { return nil }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard raw.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        return "#\(raw.uppercased())"
    }

    public static func slug(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var previousWasDash = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "theme" : trimmed
    }
}

public extension ColorTheme {
    var terminalTheme: TerminalColorTheme {
        TerminalColorTheme(
            id: rawValue,
            displayName: builtInDisplayName,
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex,
            cursorHex: defaultCursorHex,
            ansiHex: ansiHex,
            source: .builtIn
        )
    }

    private var builtInDisplayName: String {
        switch self {
        case .soyehtDark: return "Soyeht Dark"
        case .solarizedDark: return "Solarized Dark"
        case .dracula: return "Dracula"
        case .monokai: return "Monokai"
        case .highContrast: return "High Contrast"
        }
    }
}
