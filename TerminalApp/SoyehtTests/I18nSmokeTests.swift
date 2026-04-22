import Testing
import Foundation
import SoyehtCore

/// Runtime smoke test: for every supported locale, verify that a handful of
/// sentinel keys resolve to a real translation (not the key itself, not an
/// intentional "missing" placeholder). Catches two classes of regression:
///   1. A key was referenced in code but never added to Localizable.xcstrings.
///   2. An lproj bundle didn't ship with the app (build-phase or pbxproj loss).
///
/// Two @Tests — one for the iOS app bundle (`Bundle.main`) and one for the
/// SoyehtCore SPM resource bundle (`SoyehtCoreResources.bundle`). The
/// second catches regressions in the `.process("Resources/Localizable.xcstrings")`
/// directive or the `.atURL(Bundle.module.bundleURL)` wiring in public enum
/// `displayMessage`/`displayName` helpers — failure modes the JSON-level
/// coverage test (`I18nCatalogCoverageTests`) cannot detect.
@Suite("I18n Smoke")
struct I18nSmokeTests {
    private static let supportedLocales = [
        "en", "pt-BR", "pt-PT", "es", "de", "fr", "ru", "id",
        "ar", "ur", "ja", "hi", "mr", "te", "bn",
    ]

    @Test(
        "iOS app catalog sentinels resolve in every supported locale",
        arguments: supportedLocales
    )
    func iOSAppSentinelsResolve(lang: String) throws {
        // One sentinel per major surface. If any of these returns the raw key
        // or the missing-placeholder, either the catalog entry was deleted or
        // the lproj bundle for `lang` didn't ship.
        let sentinels = [
            "settings.pairedMacs.title",
            "clawstore.title",
            "common.button.cancel",
            "splash.tagline",
        ]
        try assertSentinels(in: .main, lang: lang, keys: sentinels, source: "iOS app bundle")
    }

    @Test(
        "SoyehtCore catalog sentinels resolve in every supported locale",
        arguments: supportedLocales
    )
    func soyehtCoreSentinelsResolve(lang: String) throws {
        // One sentinel per SoyehtCore surface — if any returns raw/missing, the
        // `.process` directive in Package.swift or the `.atURL(Bundle.module.bundleURL)`
        // wiring in public enum `displayMessage`/`displayName` is broken.
        let sentinels = [
            "api.error.noSession",
            "theme.name.soyehtDark",
            "unavail.notInstalled",
            "notify.claw.install.success.title",
        ]
        try assertSentinels(
            in: SoyehtCoreResources.bundle,
            lang: lang,
            keys: sentinels,
            source: "SoyehtCore resource bundle"
        )
    }

    // MARK: - Helpers

    private func assertSentinels(
        in rootBundle: Bundle,
        lang: String,
        keys: [String],
        source: String
    ) throws {
        let bundle = try #require(
            rootBundle.url(forResource: lang, withExtension: "lproj").flatMap(Bundle.init(url:)),
            "No \(lang).lproj in \(source) — build may have dropped the locale"
        )
        for key in keys {
            let resolved = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            #expect(resolved != "__MISSING__", "[\(source)] key \(key) missing in \(lang)")
            #expect(resolved != key, "[\(source)] key \(key) returned raw in \(lang) — lproj probably didn't ship this entry")
        }
    }
}
