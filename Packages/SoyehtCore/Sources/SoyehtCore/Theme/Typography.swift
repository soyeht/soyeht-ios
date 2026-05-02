import SwiftUI
import CoreGraphics
import CoreText

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

// Single source of truth for typography across iOS, macOS and Live Activity.
// Monospaced tokens resolve to JetBrains Mono (bundled .ttf, registered via
// UIAppFonts / ATSApplicationFontsPath). Sans tokens resolve to SF (system).
// Never use `Font.system(..., design: .monospaced)` inline — always a token.

public enum Typography {

    // MARK: - PostScript Names (JetBrains Mono v2.304)

    public static let monoRegularPS    = "JetBrainsMono-Regular"
    public static let monoMediumPS     = "JetBrainsMono-Medium"
    public static let monoSemiBoldPS   = "JetBrainsMono-SemiBold"
    public static let monoBoldPS       = "JetBrainsMono-Bold"
    public static let monoItalicPS     = "JetBrainsMono-Italic"
    public static let monoBoldItalicPS = "JetBrainsMono-BoldItalic"

    public static let monoFamily = "JetBrains Mono"

    /// Global UI-token scale. Multiplied into every named token size so the
    /// whole interface can be scaled at once, with a hard 12pt floor for named
    /// UI tokens. Terminal font size (passed through `monoUIFont(size:)` /
    /// `monoNSFont(size:)` from user preference) is intentionally NOT scaled —
    /// the user picks it explicitly via the FontSizeView slider.
    public static let uiScale: CGFloat = 1.2
    public static let minimumUISize: CGFloat = 12
    private static let compactUISize: CGFloat = minimumUISize * 1.1

    public static let allPostScriptNames: [String] = [
        monoRegularPS, monoMediumPS, monoSemiBoldPS,
        monoBoldPS, monoItalicPS, monoBoldItalicPS
    ]

    // MARK: - Weight

    public enum Weight: Sendable {
        case regular, medium, semibold, bold
    }

    static func postScriptName(weight: Weight, italic: Bool) -> String {
        switch (weight, italic) {
        case (.regular, false):  return monoRegularPS
        case (.medium, false):   return monoMediumPS
        case (.semibold, false): return monoSemiBoldPS
        case (.bold, false):     return monoBoldPS
        // Only Italic and BoldItalic variants are bundled; medium/semibold italic
        // fall back to the closest bundled italic cut.
        case (.regular, true),
             (.medium, true):    return monoItalicPS
        case (.semibold, true),
             (.bold, true):      return monoBoldItalicPS
        }
    }

    // MARK: - SwiftUI Font (cross-platform)

    public static func mono(size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> Font {
        Font.custom(postScriptName(weight: weight, italic: italic), size: size)
    }

    public static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }

    public static func uiSize(_ size: CGFloat) -> CGFloat {
        max(minimumUISize, size * uiScale)
    }

    public static func clampedUISize(_ size: CGFloat) -> CGFloat {
        max(minimumUISize, size)
    }

    public static func monoRelative(_ style: Font.TextStyle, weight: Weight = .regular, italic: Bool = false) -> Font {
        Font.custom(
            postScriptName(weight: weight, italic: italic),
            size: baseSize(for: style),
            relativeTo: style
        )
    }

    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:  return uiSize(34)
        case .title:       return uiSize(28)
        case .title2:      return uiSize(22)
        case .title3:      return uiSize(20)
        case .headline:    return uiSize(17)
        case .body:        return uiSize(17)
        case .callout:     return uiSize(16)
        case .subheadline: return uiSize(15)
        case .footnote:    return uiSize(13)
        case .caption:     return uiSize(12)
        case .caption2:    return compactUISize
        @unknown default:  return uiSize(17)
        }
    }

    // MARK: - Semantic Groups (SwiftUI)

    public enum Display {
        public static let pageTitle    = Typography.mono(size: Typography.uiSize(24), weight: .bold)
        public static let heading      = Typography.mono(size: Typography.uiSize(20), weight: .bold)
        public static let monoLarge    = Typography.mono(size: Typography.uiSize(32), weight: .bold)
        public static let monoHuge     = Typography.mono(size: Typography.uiSize(48), weight: .regular)
        public static let sansLight    = Font.system(size: Typography.uiSize(48), weight: .light, design: .default)
        public static let sansRegular  = Font.system(size: Typography.uiSize(48), weight: .regular, design: .default)
    }

    public enum Navigation {
        public static let title     = Typography.mono(size: Typography.uiSize(18), weight: .semibold)
        public static let titleBold = Typography.mono(size: Typography.uiSize(18), weight: .bold)
        public static let sansTitle = Font.system(size: Typography.uiSize(14), weight: .medium, design: .default)
    }

    public enum Sections {
        public static let title        = Typography.mono(size: Typography.uiSize(16), weight: .bold)
        public static let regular      = Typography.mono(size: Typography.uiSize(16), weight: .regular)
        public static let medium       = Typography.mono(size: Typography.uiSize(16), weight: .medium)
        public static let semibold     = Typography.mono(size: Typography.uiSize(16), weight: .semibold)
        public static let sansTitle    = Font.system(size: Typography.uiSize(16), weight: .regular, design: .default)
        public static let sansHeading  = Font.system(size: Typography.uiSize(18), weight: .regular, design: .default)
        public static let smallLabel   = Typography.mono(size: Typography.minimumUISize, weight: .semibold)
    }

    public enum Text {
        public static let bodyLarge       = Typography.mono(size: Typography.uiSize(15), weight: .regular)
        public static let bodyLargeMedium = Typography.mono(size: Typography.uiSize(15), weight: .medium)
        public static let bodyLargeSemi   = Typography.mono(size: Typography.uiSize(15), weight: .semibold)
        public static let bodyLargeBold   = Typography.mono(size: Typography.uiSize(15), weight: .bold)

        public static let body       = Typography.mono(size: Typography.uiSize(14), weight: .regular)
        public static let bodyMedium = Typography.mono(size: Typography.uiSize(14), weight: .medium)
        public static let bodySemi   = Typography.mono(size: Typography.uiSize(14), weight: .semibold)
        public static let bodyBold   = Typography.mono(size: Typography.uiSize(14), weight: .bold)

        public static let small       = Typography.mono(size: Typography.minimumUISize, weight: .regular)
        public static let smallMedium = Typography.mono(size: Typography.minimumUISize, weight: .medium)
        public static let smallBold   = Typography.mono(size: Typography.minimumUISize, weight: .bold)

        public static let micro       = Typography.mono(size: Typography.minimumUISize, weight: .regular)
        public static let microMedium = Typography.mono(size: Typography.minimumUISize, weight: .medium)
        public static let microBold   = Typography.mono(size: Typography.minimumUISize, weight: .semibold)

        public static let sansBody     = Font.system(size: Typography.uiSize(14), weight: .regular, design: .default)
        public static let sansSubtitle = Font.system(size: Typography.uiSize(14), weight: .regular, design: .default)
        public static let sansSmall    = Font.system(size: Typography.compactUISize, weight: .medium, design: .default)
    }

    public enum Controls {
        public static let labelRegular = Typography.mono(size: Typography.uiSize(12), weight: .regular)
        public static let label        = Typography.mono(size: Typography.uiSize(12), weight: .medium)
        public static let labelBold    = Typography.mono(size: Typography.uiSize(12), weight: .bold)

        public static let tag       = Typography.mono(size: Typography.compactUISize, weight: .regular)
        public static let tagMedium = Typography.mono(size: Typography.compactUISize, weight: .medium)
        public static let tagSemi   = Typography.mono(size: Typography.compactUISize, weight: .semibold)
    }

    public enum Cards {
        public static let body   = Typography.mono(size: Typography.uiSize(13), weight: .regular)
        public static let medium = Typography.mono(size: Typography.uiSize(13), weight: .medium)
        public static let title  = Typography.mono(size: Typography.uiSize(13), weight: .semibold)
        public static let sansBody = Font.system(size: Typography.uiSize(13), weight: .regular, design: .default)
    }

    public enum Status {
        public static let badge       = Controls.tag
        public static let badgeMedium = Controls.tagMedium
        public static let badgeStrong = Controls.tagSemi
        public static let caption     = Text.small
        public static let captionBold = Text.smallBold
    }

    public enum LiveActivity {
        public static let subheadline     = Typography.monoRelative(.subheadline)
        public static let subheadlineBold = Typography.monoRelative(.subheadline, weight: .bold)
        public static let caption         = Typography.monoRelative(.caption)
        public static let captionBold     = Typography.monoRelative(.caption, weight: .bold)
        public static let caption2        = Typography.monoRelative(.caption2)
        public static let caption2Bold    = Typography.monoRelative(.caption2, weight: .bold)
        public static let title3Bold      = Typography.monoRelative(.title3, weight: .bold)
    }

    public enum Icons {
        public static let small      = Font.system(size: Typography.uiSize(13), weight: .regular, design: .default)
        public static let navigation = Font.system(size: Typography.uiSize(12), weight: .medium, design: .default)
        public static let medium     = Font.system(size: Typography.uiSize(15), weight: .regular, design: .default)
        public static let status     = Font.system(size: Typography.uiSize(20), weight: .regular, design: .default)
        public static let statusBold = Font.system(size: Typography.uiSize(14), weight: .bold, design: .default)
        public static let emptyState = Font.system(size: Typography.uiSize(30), weight: .regular, design: .default)

        public static let navigationPointSize: CGFloat = Typography.minimumUISize
        public static let smallPointSize: CGFloat = 13
        public static let statusBoldPointSize: CGFloat = 14
        public static let mediumPointSize: CGFloat = 16
        public static let actionPointSize: CGFloat = 17
        public static let largePointSize: CGFloat = 24
        public static let heroPointSize: CGFloat = 64
    }

    // MARK: - Legacy Aliases

    public static let monoPageTitle    = Display.pageTitle
    public static let monoHeading      = Display.heading
    public static let monoNavTitle     = Navigation.title
    public static let monoNavTitleBold = Navigation.titleBold

    public static let monoSection        = Sections.title
    public static let monoSectionRegular = Sections.regular
    public static let monoSectionMedium  = Sections.medium
    public static let monoSectionSemi    = Sections.semibold

    public static let monoBodyLarge       = Text.bodyLarge
    public static let monoBodyLargeMedium = Text.bodyLargeMedium
    public static let monoBodyLargeSemi   = Text.bodyLargeSemi
    public static let monoBodyLargeBold   = Text.bodyLargeBold

    public static let monoBody       = Text.body
    public static let monoBodyMedium = Text.bodyMedium
    public static let monoBodySemi   = Text.bodySemi
    public static let monoBodyBold   = Text.bodyBold

    public static let monoCardBody   = Cards.body
    public static let monoCardMedium = Cards.medium
    public static let monoCardTitle  = Cards.title

    public static let monoLabelRegular = Controls.labelRegular
    public static let monoLabel        = Controls.label
    public static let monoLabelBold    = Controls.labelBold

    public static let monoTag       = Controls.tag
    public static let monoTagMedium = Controls.tagMedium
    public static let monoTagSemi   = Controls.tagSemi

    public static let monoSmall        = Text.small
    public static let monoSmallMedium  = Text.smallMedium
    public static let monoSectionLabel = Sections.smallLabel
    public static let monoSmallBold    = Text.smallBold

    public static let monoMicro       = Text.micro
    public static let monoMicroMedium = Text.microMedium
    public static let monoMicroBold   = Text.microBold

    public static let monoDisplay     = Display.monoLarge
    public static let monoDisplayHuge = Display.monoHuge

    public static let monoSubheadline     = LiveActivity.subheadline
    public static let monoSubheadlineBold = LiveActivity.subheadlineBold
    public static let monoCaption         = LiveActivity.caption
    public static let monoCaptionBold     = LiveActivity.captionBold
    public static let monoCaption2        = LiveActivity.caption2
    public static let monoCaption2Bold    = LiveActivity.caption2Bold
    public static let monoTitle3Bold      = LiveActivity.title3Bold

    public static let sansNav          = Navigation.sansTitle
    public static let sansBody         = Text.sansBody
    public static let sansSubtitle     = Text.sansSubtitle
    public static let sansSection      = Sections.sansTitle
    public static let sansHeading      = Sections.sansHeading
    public static let sansCard         = Cards.sansBody
    public static let sansSmall        = Text.sansSmall
    public static let sansDisplayLight = Display.sansLight
    public static let sansDisplay      = Display.sansRegular

    public static let iconSmall      = Icons.small
    public static let iconNav        = Icons.navigation
    public static let iconMedium     = Icons.medium
    public static let iconStatus     = Icons.status
    public static let iconStatusBold = Icons.statusBold
    public static let iconEmptyState = Icons.emptyState

    public static let iconNavPointSize = Icons.navigationPointSize
    public static let iconSmallPointSize = Icons.smallPointSize
    public static let iconStatusBoldPointSize = Icons.statusBoldPointSize
    public static let iconMediumPointSize = Icons.mediumPointSize
    public static let iconActionPointSize = Icons.actionPointSize
    public static let iconLargePointSize = Icons.largePointSize
    public static let iconHeroPointSize = Icons.heroPointSize

    // MARK: - UIKit (iOS)

    #if canImport(UIKit)

    public enum UIKitFonts {
        public enum Labels {
            public static var monoRegular: UIFont { monoUIFont(size: minimumUISize, weight: .regular) }
            public static var monoMedium: UIFont { monoUIFont(size: minimumUISize, weight: .medium) }
            public static var monoSemi: UIFont { monoUIFont(size: minimumUISize, weight: .semibold) }
            public static var sansMedium: UIFont { UIFont.systemFont(ofSize: minimumUISize, weight: .medium) }
        }

        public enum Cards {
            public static var monoRegular: UIFont { monoUIFont(size: 13, weight: .regular) }
            public static var monoMedium: UIFont { monoUIFont(size: 13, weight: .medium) }
        }

        public enum Sections {
            public static var monoTitle: UIFont { monoUIFont(size: 14, weight: .medium) }
        }

        public enum Controls {
            public static var monoButton: UIFont { monoUIFont(size: 15, weight: .medium) }
        }
    }

    public static var monoUILabelRegular: UIFont { UIKitFonts.Labels.monoRegular }
    public static var monoUILabelMedium: UIFont { UIKitFonts.Labels.monoMedium }
    public static var monoUILabelSemi: UIFont { UIKitFonts.Labels.monoSemi }
    public static var monoUICardRegular: UIFont { UIKitFonts.Cards.monoRegular }
    public static var monoUICardMedium: UIFont { UIKitFonts.Cards.monoMedium }
    public static var monoUISection: UIFont { UIKitFonts.Sections.monoTitle }
    public static var monoUIButton: UIFont { UIKitFonts.Controls.monoButton }
    public static var sansUILabelMedium: UIFont { UIKitFonts.Labels.sansMedium }

    public static func monoUIFont(size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> UIFont {
        let ps = postScriptName(weight: weight, italic: italic)
        guard let f = UIFont(name: ps, size: size) else {
            fatalError("""
            [Typography] JetBrains Mono (\(ps)) is not resolvable. bootstrap() must be
            called before any font lookup, and the .ttf must ship in SoyehtCore resources.
            Refusing to return a fallback — JetBrains Mono is a hard brand requirement.
            """)
        }
        return f
    }

    #endif

    // MARK: - AppKit (macOS)

    #if canImport(AppKit)

    public static func monoNSFont(size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> NSFont {
        let ps = postScriptName(weight: weight, italic: italic)
        guard let f = NSFont(name: ps, size: size) else {
            fatalError("""
            [Typography] JetBrains Mono (\(ps)) is not resolvable. bootstrap() must be
            called before any font lookup, and the .ttf must ship in SoyehtCore resources.
            Refusing to return a fallback — JetBrains Mono is a hard brand requirement.
            """)
        }
        return f
    }

    public static func sansNSFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    #endif

    // MARK: - Bootstrap

    /// Registers the bundled JetBrains Mono .ttf files with Core Text for the
    /// current process and verifies every PostScript name resolves. Must be
    /// called exactly once at launch from every process that renders text:
    /// iOS AppDelegate, macOS AppDelegate, SoyehtLiveActivityBundle.init.
    /// Registration is scoped to the calling process — extensions do NOT
    /// inherit from the host app.
    ///
    /// **Brand-critical:** crashes hard (`fatalError`) in both debug and
    /// release builds if any font is missing or fails to register. Shipping
    /// with SF Mono as a silent fallback is unacceptable — rather crash in a
    /// way that surfaces in crash analytics than render the wrong typeface.
    public static func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        let files = [
            "JetBrainsMono-Regular",
            "JetBrainsMono-Medium",
            "JetBrainsMono-SemiBold",
            "JetBrainsMono-Bold",
            "JetBrainsMono-Italic",
            "JetBrainsMono-BoldItalic",
        ]

        var urls: [URL] = []
        for name in files {
            // `.copy("Resources/Fonts")` in Package.swift places .ttf files under
            // the "Fonts" subdirectory of Bundle.module (not at the root).
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf") else {
                fatalError("""
                [Typography] Missing bundled font: \(name).ttf

                JetBrains Mono is a brand/marketing requirement and must ship with
                every build. Expected path:
                  Packages/SoyehtCore/Sources/SoyehtCore/Resources/Fonts/\(name).ttf

                Package.swift must declare `.copy("Resources/Fonts")` on the SoyehtCore target.
                """)
            }
            urls.append(url)
        }

        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)

        // Verify every PostScript name resolves immediately after registration.
        // If any does not, we refuse to continue — rendering with SF Mono as
        // a fallback is worse than crashing for this project.
        for ps in allPostScriptNames {
            if !isPostScriptNameAvailable(ps) {
                fatalError("""
                [Typography] JetBrains Mono registration failed after CTFontManagerRegisterFontURLs:
                PostScript name '\(ps)' is not resolvable via UIFont(name:) / NSFont(name:).
                Refusing to render with a fallback typeface — JetBrains Mono is a hard requirement.
                """)
            }
        }
    }

    private static var didBootstrap = false

    private static func isPostScriptNameAvailable(_ ps: String) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: ps, size: minimumUISize) != nil
        #elseif canImport(AppKit)
        return NSFont(name: ps, size: minimumUISize) != nil
        #else
        return false
        #endif
    }

    /// True when every JetBrains Mono PostScript name resolves on the current
    /// platform. After `bootstrap()` succeeds this always returns true (or
    /// bootstrap would have crashed). Useful for test assertions.
    public static func isRegistered() -> Bool {
        allPostScriptNames.allSatisfy(isPostScriptNameAvailable)
    }

    // MARK: - WebKit / HTML embedding

    /// CSS `@font-face` declarations embedding the bundled JetBrains Mono TTFs
    /// (Regular, Bold, Italic, BoldItalic) as base64 data URLs. Inject inside
    /// a `<style>` block in any `WKWebView` HTML so the brand monospaced font
    /// renders independent of whether JetBrains Mono is installed system-wide
    /// (iOS webviews do NOT inherit fonts from `UIAppFonts` or
    /// `CTFontManagerRegisterFontURLs` — they see only their own CSS resources).
    ///
    /// **Brand-critical:** `fatalError` in both debug and release if any TTF is
    /// missing from the bundle. Cached (evaluated once per process).
    public static let webFontFaceCSS: String = {
        let variants: [(weight: String, style: String, file: String)] = [
            ("400", "normal", monoRegularPS),
            ("700", "normal", monoBoldPS),
            ("400", "italic", monoItalicPS),
            ("700", "italic", monoBoldItalicPS),
        ]
        return variants.map { v in
            guard let url = Bundle.module.url(forResource: v.file, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: v.file, withExtension: "ttf"),
                  let data = try? Data(contentsOf: url) else {
                fatalError("""
                [Typography] Missing bundled font for WebKit embed: \(v.file).ttf.
                JetBrains Mono must ship with the app — this is a hard brand requirement.
                """)
            }
            return """
            @font-face {
              font-family: 'JetBrains Mono';
              font-weight: \(v.weight);
              font-style: \(v.style);
              src: url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');
            }
            """
        }.joined(separator: "\n")
    }()
}
