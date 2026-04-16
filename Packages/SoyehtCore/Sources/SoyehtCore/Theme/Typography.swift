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
    /// whole interface can be scaled at once. Terminal font size (passed
    /// through `monoUIFont(size:)` / `monoNSFont(size:)` from user preference)
    /// is intentionally NOT scaled — the user picks it explicitly via the
    /// FontSizeView slider.
    public static let uiScale: CGFloat = 1.2

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

    public static func monoRelative(_ style: Font.TextStyle, weight: Weight = .regular, italic: Bool = false) -> Font {
        Font.custom(
            postScriptName(weight: weight, italic: italic),
            size: baseSize(for: style),
            relativeTo: style
        )
    }

    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:  return 34 * uiScale
        case .title:       return 28 * uiScale
        case .title2:      return 22 * uiScale
        case .title3:      return 20 * uiScale
        case .headline:    return 17 * uiScale
        case .body:        return 17 * uiScale
        case .callout:     return 16 * uiScale
        case .subheadline: return 15 * uiScale
        case .footnote:    return 13 * uiScale
        case .caption:     return 12 * uiScale
        case .caption2:    return 11 * uiScale
        @unknown default:  return 17 * uiScale
        }
    }

    // MARK: - Tokens (mono, absolute sizes)

    public static let monoPageTitle    = mono(size: 24 * uiScale, weight: .bold)
    public static let monoHeading      = mono(size: 20 * uiScale, weight: .bold)
    public static let monoNavTitle     = mono(size: 18 * uiScale, weight: .semibold)
    public static let monoNavTitleBold = mono(size: 18 * uiScale, weight: .bold)

    public static let monoSection        = mono(size: 16 * uiScale, weight: .bold)
    public static let monoSectionRegular = mono(size: 16 * uiScale, weight: .regular)
    public static let monoSectionMedium  = mono(size: 16 * uiScale, weight: .medium)
    public static let monoSectionSemi    = mono(size: 16 * uiScale, weight: .semibold)

    public static let monoBodyLarge       = mono(size: 15 * uiScale, weight: .regular)
    public static let monoBodyLargeMedium = mono(size: 15 * uiScale, weight: .medium)
    public static let monoBodyLargeSemi   = mono(size: 15 * uiScale, weight: .semibold)
    public static let monoBodyLargeBold   = mono(size: 15 * uiScale, weight: .bold)

    public static let monoBody       = mono(size: 14 * uiScale, weight: .regular)
    public static let monoBodyMedium = mono(size: 14 * uiScale, weight: .medium)
    public static let monoBodySemi   = mono(size: 14 * uiScale, weight: .semibold)
    public static let monoBodyBold   = mono(size: 14 * uiScale, weight: .bold)

    public static let monoCardBody   = mono(size: 13 * uiScale, weight: .regular)
    public static let monoCardMedium = mono(size: 13 * uiScale, weight: .medium)
    public static let monoCardTitle  = mono(size: 13 * uiScale, weight: .semibold)

    public static let monoLabelRegular = mono(size: 12 * uiScale, weight: .regular)
    public static let monoLabel        = mono(size: 12 * uiScale, weight: .medium)
    public static let monoLabelBold    = mono(size: 12 * uiScale, weight: .bold)

    public static let monoTag       = mono(size: 11 * uiScale, weight: .regular)
    public static let monoTagMedium = mono(size: 11 * uiScale, weight: .medium)
    public static let monoTagSemi   = mono(size: 11 * uiScale, weight: .semibold)

    public static let monoSmall        = mono(size: 10 * uiScale, weight: .regular)
    public static let monoSmallMedium  = mono(size: 10 * uiScale, weight: .medium)
    public static let monoSectionLabel = mono(size: 10 * uiScale, weight: .semibold)
    public static let monoSmallBold    = mono(size: 10 * uiScale, weight: .bold)

    public static let monoMicro       = mono(size: 9 * uiScale, weight: .regular)
    public static let monoMicroMedium = mono(size: 9 * uiScale, weight: .medium)
    public static let monoMicroBold   = mono(size: 9 * uiScale, weight: .semibold)

    public static let monoDisplay     = mono(size: 32 * uiScale, weight: .bold)
    public static let monoDisplayHuge = mono(size: 48 * uiScale, weight: .regular)

    // MARK: - Tokens (mono, Dynamic Type — for Live Activity widget)

    public static let monoSubheadline     = monoRelative(.subheadline)
    public static let monoSubheadlineBold = monoRelative(.subheadline, weight: .bold)
    public static let monoCaption         = monoRelative(.caption)
    public static let monoCaptionBold     = monoRelative(.caption, weight: .bold)
    public static let monoCaption2        = monoRelative(.caption2)
    public static let monoCaption2Bold    = monoRelative(.caption2, weight: .bold)
    public static let monoTitle3Bold      = monoRelative(.title3, weight: .bold)

    // MARK: - Sans (SF, .default)

    public static let sansNav          = Font.system(size: 14 * uiScale, weight: .medium, design: .default)
    public static let sansBody         = Font.system(size: 14 * uiScale, weight: .regular, design: .default)
    public static let sansSubtitle     = Font.system(size: 14 * uiScale, weight: .regular, design: .default)
    public static let sansSection      = Font.system(size: 16 * uiScale, weight: .regular, design: .default)
    public static let sansHeading      = Font.system(size: 18 * uiScale, weight: .regular, design: .default)
    public static let sansCard         = Font.system(size: 13 * uiScale, weight: .regular, design: .default)
    public static let sansSmall        = Font.system(size: 11 * uiScale, weight: .medium, design: .default)
    public static let sansDisplayLight = Font.system(size: 48 * uiScale, weight: .light, design: .default)
    public static let sansDisplay      = Font.system(size: 48 * uiScale, weight: .regular, design: .default)

    // MARK: - UIKit (iOS)

    #if canImport(UIKit)

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
        return UIFont(name: ps, size: 12) != nil
        #elseif canImport(AppKit)
        return NSFont(name: ps, size: 12) != nil
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
