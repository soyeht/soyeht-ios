import Foundation

/// App-level semantic palette derived directly from a terminal color theme.
///
/// The mapping intentionally does not synthesize new colors. Every stored hex
/// value comes from `background`, `foreground`, `cursor`, optional terminal
/// semantic colors, or one of the 16 ANSI slots in the source terminal theme.
public struct SoyehtAppPalette: Equatable, Sendable {
    public let backgroundHex: String
    public let surfaceHex: String
    public let surfaceRaisedHex: String
    public let cardHex: String
    public let borderHex: String
    public let hoverHex: String

    public let textPrimaryHex: String
    public let textSecondaryHex: String
    public let textMutedHex: String
    public let readableTextOnBackgroundHex: String
    public let readableSecondaryTextOnBackgroundHex: String

    public let accentHex: String
    public let selectionHex: String
    public let selectionTextHex: String
    public let readableTextOnSelectionHex: String
    public let cursorTextHex: String
    public let dangerHex: String
    public let successHex: String
    public let warningHex: String
    public let linkHex: String
    public let alternateHex: String
    public let infoHex: String

    public let dangerStrongHex: String
    public let successStrongHex: String
    public let warningStrongHex: String
    public let linkStrongHex: String
    public let alternateStrongHex: String
    public let infoStrongHex: String

    public let buttonTextOnAccentHex: String

    public init(theme: TerminalColorTheme) {
        let background = theme.backgroundHex
        let foreground = theme.foregroundHex
        let cursor = theme.cursorHex
        let cursorText = theme.cursorTextHex ?? background
        let selectionBackground = theme.selectionBackgroundHex ?? cursor
        let selectionForeground = theme.selectionForegroundHex ?? cursorText
        precondition(theme.ansiHex.count == 16, "Terminal app palette requires exactly 16 ANSI colors.")
        let ansi = theme.ansiHex
        let sourceColors = Self.sourceColors(
            background: background,
            foreground: foreground,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            bold: theme.boldHex,
            link: theme.linkHex,
            ansi: ansi,
            extra: theme.extraHexColors
        )

        self.backgroundHex = background
        self.surfaceHex = background
        self.surfaceRaisedHex = background
        self.cardHex = background
        self.borderHex = ansi[8]
        self.hoverHex = background

        self.textPrimaryHex = foreground
        self.textSecondaryHex = ansi[7]
        self.textMutedHex = ansi[8]
        self.readableTextOnBackgroundHex = Self.readableColor(
            on: background,
            preferred: [foreground, theme.boldHex, ansi[7], ansi[15], ansi[0]],
            sourceColors: sourceColors,
            minimumContrast: Self.bodyTextMinimumContrast
        )
        self.readableSecondaryTextOnBackgroundHex = Self.readableColor(
            on: background,
            preferred: [ansi[7], foreground, theme.boldHex, ansi[15], ansi[8]],
            sourceColors: sourceColors,
            minimumContrast: Self.bodyTextMinimumContrast
        )

        self.accentHex = cursor
        self.selectionHex = selectionBackground
        self.selectionTextHex = selectionForeground
        self.readableTextOnSelectionHex = Self.readableColor(
            on: selectionBackground,
            preferred: [selectionForeground, cursorText, foreground, background, ansi[15], ansi[0]],
            sourceColors: sourceColors,
            minimumContrast: Self.bodyTextMinimumContrast
        )
        self.cursorTextHex = cursorText
        self.dangerHex = ansi[1]
        self.successHex = ansi[2]
        self.warningHex = ansi[3]
        self.linkHex = theme.linkHex ?? ansi[4]
        self.alternateHex = ansi[5]
        self.infoHex = ansi[6]

        self.dangerStrongHex = ansi[9]
        self.successStrongHex = ansi[10]
        self.warningStrongHex = ansi[11]
        self.linkStrongHex = ansi[12]
        self.alternateStrongHex = ansi[13]
        self.infoStrongHex = ansi[14]

        self.buttonTextOnAccentHex = Self.readableColor(
            on: cursor,
            preferred: [cursorText, background, foreground, selectionForeground, ansi[15], ansi[0]],
            sourceColors: sourceColors,
            minimumContrast: Self.bodyTextMinimumContrast
        )
    }

    public var allHexValues: [String] {
        [
            backgroundHex, surfaceHex, surfaceRaisedHex, cardHex, borderHex, hoverHex,
            textPrimaryHex, textSecondaryHex, textMutedHex,
            readableTextOnBackgroundHex, readableSecondaryTextOnBackgroundHex,
            accentHex, selectionHex, selectionTextHex, readableTextOnSelectionHex, cursorTextHex,
            dangerHex, successHex, warningHex, linkHex, alternateHex, infoHex,
            dangerStrongHex, successStrongHex, warningStrongHex, linkStrongHex,
            alternateStrongHex, infoStrongHex, buttonTextOnAccentHex,
        ]
    }

    public var isDark: Bool {
        Self.relativeLuminance(backgroundHex) < 0.5
    }

    private static let bodyTextMinimumContrast = 4.5

    private static func sourceColors(
        background: String,
        foreground: String,
        cursor: String,
        cursorText: String,
        selectionBackground: String,
        selectionForeground: String,
        bold: String?,
        link: String?,
        ansi: [String],
        extra: [String: String]
    ) -> [String] {
        uniqueHexes(
            [background, foreground, cursor, cursorText, selectionBackground, selectionForeground]
            + [bold, link].compactMap { $0 }
            + ansi
            + extra.sorted { $0.key < $1.key }.map(\.value)
        )
    }

    private static func uniqueHexes(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private static func readableColor(
        on background: String,
        preferred: [String?],
        sourceColors: [String],
        minimumContrast: Double
    ) -> String {
        let preferredColors = uniqueHexes(preferred.compactMap { $0 })
        for color in preferredColors where contrastRatio(color, background) >= minimumContrast {
            return color
        }

        let candidates = uniqueHexes(preferredColors + sourceColors)
        return candidates.max {
            contrastRatio($0, background) < contrastRatio($1, background)
        } ?? preferredColors.first ?? background
    }

    private static func contrastRatio(_ foreground: String, _ background: String) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ hex: String) -> Double {
        let (red, green, blue) = ColorTheme.rgb8(from: hex)
        func channel(_ value: UInt8) -> Double {
            let component = Double(value) / 255.0
            if component <= 0.03928 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

public extension TerminalColorTheme {
    var appPalette: SoyehtAppPalette {
        SoyehtAppPalette(theme: self)
    }
}
