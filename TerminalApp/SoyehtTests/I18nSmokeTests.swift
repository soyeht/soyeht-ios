import Testing
import Foundation

/// Runtime smoke test: for every supported locale, verify that a handful of
/// sentinel keys resolve to a real translation (not the key itself, not an
/// intentional "missing" placeholder). Catches two classes of regression:
///   1. A key was referenced in code but never added to Localizable.xcstrings.
///   2. An lproj bundle didn't ship with the app (build-phase or pbxproj loss).
///
/// Catalog-coverage (every key × every locale) is enforced by the SPM test
/// `I18nCatalogCoverageTests` in SoyehtMacTests — that reads the JSON directly
/// and doesn't need the app bundle.
@Suite("I18n Smoke")
struct I18nSmokeTests {
    @Test(
        "Sentinels resolve in every supported locale",
        arguments: ["en", "pt-BR", "pt-PT", "es", "de", "fr", "ru", "id", "ar", "ur", "ja", "hi", "mr", "te", "bn"]
    )
    func sentinelsResolve(lang: String) throws {
        // One sentinel per major surface. If any of these returns the raw key
        // or the missing-placeholder, either the catalog entry was deleted or
        // the lproj bundle for `lang` didn't ship.
        let sentinels = [
            "settings.pairedMacs.title",
            "clawstore.title",
            "common.button.cancel",
            "splash.tagline",
        ]
        let bundle = try #require(
            Bundle.main.url(forResource: lang, withExtension: "lproj").flatMap(Bundle.init(url:)),
            "No \(lang).lproj bundle — Xcode build may have dropped the locale"
        )
        for key in sentinels {
            let resolved = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            #expect(resolved != "__MISSING__", "key \(key) missing in \(lang)")
            #expect(resolved != key, "key \(key) returned raw in \(lang) — lproj probably didn't ship this entry")
        }
    }
}
