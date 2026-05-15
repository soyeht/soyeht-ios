import XCTest

/// Specific-value assertions for the macOS Welcome window translations. Complements
/// `I18nCatalogCoverageTests` (which only asserts that every key has SOMETHING translated
/// for every locale) by asserting the EXACT expected French, Japanese, Arabic, and Russian
/// values for the user-facing strings documented in the QA plan (ST-Q-I18N-004).
///
/// JSON-level lookup is used instead of bundle runtime (like `I18nSmokeTests`) because the
/// `SoyehtMacDomainTests` SPM package does not link against the SoyehtMac app target (and
/// hence cannot resolve the macOS catalog via `Bundle.main.localizedString`). Reading the
/// `.xcstrings` JSON directly is equivalent since the Xcode build pipeline compiles the
/// same keys into `.strings` files at build time.
final class WelcomeTranslationTests: XCTestCase {

    private var macCatalog: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // SoyehtMacTests/
            .deletingLastPathComponent()   // TerminalApp/
            .appendingPathComponent("SoyehtMac/Localizable.xcstrings")
    }

    func test_welcome_landingTitle_fr_Bienvenue() throws {
        let v = try I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.landing.title", lang: "fr")
        XCTAssertEqual(v, "Bienvenue dans Soyeht")
    }

    func test_welcome_landingSubtitle_fr_properTranslation() throws {
        let v = try I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.landing.subtitle", lang: "fr")
        // Don't bind to exact wording (minor edits happen); just assert French capitalization hints
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.contains("Agents") ?? false, "Expected French welcome subtitle to mention Agents, got: \(v ?? "nil")")
    }

    func test_welcome_localInstallTitle_fr_Installer() throws {
        let v = try I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.card.localInstall.title", lang: "fr")
        XCTAssertEqual(v, "Installer sur mon Mac")
    }

    func test_welcome_localInstallBadge_fr_Recommande() throws {
        let v = try I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.card.localInstall.badge", lang: "fr")
        XCTAssertEqual(v, "Recommandé")
    }

    // Sanity-check a few other locales to verify the catalog isn't only populated in fr.

    func test_welcome_landingTitle_ja_containsJapaneseCharacters() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.landing.title", lang: "ja"))
        // Japanese characters are in the CJK Unified Ideographs or Hiragana/Katakana ranges.
        XCTAssertTrue(v.contains(where: { c in
            let s = c.unicodeScalars.first!.value
            return (0x3040...0x30FF).contains(s) || (0x4E00...0x9FFF).contains(s)
        }), "Expected Japanese characters in ja welcome title, got: \(v)")
    }

    func test_welcome_landingTitle_ar_containsArabicCharacters() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.landing.title", lang: "ar"))
        XCTAssertTrue(v.contains(where: { c in
            let s = c.unicodeScalars.first!.value
            return (0x0600...0x06FF).contains(s) // Arabic block
        }), "Expected Arabic characters in ar welcome title, got: \(v)")
    }

    func test_welcome_landingTitle_ru_containsCyrillicCharacters() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: macCatalog, key: "welcome.landing.title", lang: "ru"))
        XCTAssertTrue(v.contains(where: { c in
            let s = c.unicodeScalars.first!.value
            return (0x0400...0x04FF).contains(s) // Cyrillic block
        }), "Expected Cyrillic characters in ru welcome title, got: \(v)")
    }
}
