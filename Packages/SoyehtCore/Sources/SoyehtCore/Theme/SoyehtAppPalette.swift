import Foundation

/// App-level semantic palette derived directly from a terminal color theme.
///
/// The mapping intentionally does not synthesize new colors. Every stored hex
/// value comes from `background`, `foreground`, `cursor`, or one of the 16 ANSI
/// slots in the source terminal theme.
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

    public let accentHex: String
    public let selectionHex: String
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
        precondition(theme.ansiHex.count == 16, "Terminal app palette requires exactly 16 ANSI colors.")
        let ansi = theme.ansiHex

        self.backgroundHex = background
        self.surfaceHex = background
        self.surfaceRaisedHex = background
        self.cardHex = background
        self.borderHex = ansi[8]
        self.hoverHex = background

        self.textPrimaryHex = foreground
        self.textSecondaryHex = ansi[7]
        self.textMutedHex = ansi[8]

        self.accentHex = cursor
        self.selectionHex = cursor
        self.dangerHex = ansi[1]
        self.successHex = ansi[2]
        self.warningHex = ansi[3]
        self.linkHex = ansi[4]
        self.alternateHex = ansi[5]
        self.infoHex = ansi[6]

        self.dangerStrongHex = ansi[9]
        self.successStrongHex = ansi[10]
        self.warningStrongHex = ansi[11]
        self.linkStrongHex = ansi[12]
        self.alternateStrongHex = ansi[13]
        self.infoStrongHex = ansi[14]

        self.buttonTextOnAccentHex = background
    }

    public var allHexValues: [String] {
        [
            backgroundHex, surfaceHex, surfaceRaisedHex, cardHex, borderHex, hoverHex,
            textPrimaryHex, textSecondaryHex, textMutedHex,
            accentHex, selectionHex, dangerHex, successHex, warningHex, linkHex,
            alternateHex, infoHex, dangerStrongHex, successStrongHex, warningStrongHex,
            linkStrongHex, alternateStrongHex, infoStrongHex, buttonTextOnAccentHex,
        ]
    }

    public var isDark: Bool {
        Self.relativeLuminance(backgroundHex) < 0.5
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
