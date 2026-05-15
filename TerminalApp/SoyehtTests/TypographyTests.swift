import Testing
import SwiftUI
import UIKit
import SoyehtCore

// Validates that JetBrains Mono resources bundled in SoyehtCore register
// correctly via Typography.bootstrap() and every PostScript name resolves.

@Suite struct TypographyTests {

    init() {
        // Idempotent — no-op if main app AppDelegate already bootstrapped.
        Typography.bootstrap()
    }

    @Test("All JetBrains Mono PostScript names resolve after bootstrap")
    func allPostScriptNamesRegistered() {
        #expect(Typography.isRegistered())
    }

    @Test("Each bundled weight returns a non-nil UIFont")
    func allWeightsResolve() {
        for name in Typography.allPostScriptNames {
            #expect(UIFont(name: name, size: Typography.minimumUISize) != nil, "Missing font: \(name)")
        }
    }

    @Test("monoUIFont returns JetBrains Mono regardless of requested weight")
    func monoUIFontFamily() {
        let weights: [Typography.Weight] = [.regular, .medium, .semibold, .bold]
        for w in weights {
            let f = Typography.monoUIFont(size: 14, weight: w, italic: false)
            #expect(f.familyName == Typography.monoFamily,
                    "Unexpected family for weight \(w): \(f.familyName)")
        }
    }

    @Test("Italic variant uses the Italic PostScript name")
    func italicVariant() {
        let f = Typography.monoUIFont(size: 14, weight: .regular, italic: true)
        #expect(f.fontName == Typography.monoItalicPS)
    }

    @Test("Bold+italic variant uses BoldItalic PostScript name")
    func boldItalicVariant() {
        let f = Typography.monoUIFont(size: 14, weight: .bold, italic: true)
        #expect(f.fontName == Typography.monoBoldItalicPS)
    }

    @Test("Family name is 'JetBrains Mono'")
    func familyName() {
        #expect(Typography.monoFamily == "JetBrains Mono")
    }

    @Test("UIKit grouped UI tokens respect minimum readable size")
    func uikitGroupedTokensRespectMinimumSize() {
        let fonts = [
            Typography.UIKitFonts.Labels.monoRegular,
            Typography.UIKitFonts.Labels.monoMedium,
            Typography.UIKitFonts.Labels.monoSemi,
            Typography.UIKitFonts.Labels.sansMedium,
            Typography.UIKitFonts.Cards.monoRegular,
            Typography.UIKitFonts.Cards.monoMedium,
            Typography.UIKitFonts.Sections.monoTitle,
            Typography.UIKitFonts.Controls.monoButton,
        ]

        for font in fonts {
            #expect(font.pointSize >= Typography.minimumUISize)
        }
    }

    @Test("bootstrap is idempotent")
    func idempotentBootstrap() {
        Typography.bootstrap()
        Typography.bootstrap()
        #expect(Typography.isRegistered())
    }
}
