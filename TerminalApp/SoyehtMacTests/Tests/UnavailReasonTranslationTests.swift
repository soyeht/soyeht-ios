import XCTest
import SoyehtCore

/// Validates `UnavailReason.installInProgress` and related enum cases resolve to the expected
/// localized strings per-locale (ST-Q-I18N-008). Uses JSON-level catalog lookups against the
/// SoyehtCore `Localizable.xcstrings`, because in SPM test context the xcstrings is shipped
/// raw (no per-locale `.lproj` subfolders in `Bundle.module`). Production app builds compile
/// `.lproj` folders via xcodebuild's xcstrings step — `I18nSmokeTests` already covers that
/// runtime-bundle path for iOS.
///
/// Note on plurals: `unavail.installInProgress` takes a percent (0-100), not a count, so it
/// does NOT need CLDR plural variations. The original QA plan's "plural-heavy Russian"
/// wording was about the language, not this specific key. We assert: the template renders
/// in Cyrillic/Japanese/Arabic (not English), and interpolates `%lld` correctly.
final class UnavailReasonTranslationTests: XCTestCase {

    private var coreCatalog: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings")
    }

    // MARK: - unavail.installInProgress

    func test_installInProgressTemplate_ru_containsCyrillicAndPercentPlaceholder() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "unavail.installInProgress", lang: "ru"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x0400...0x04FF).contains(s)
            }),
            "Expected Cyrillic characters in ru installInProgress template, got: \(v)"
        )
        XCTAssertTrue(v.contains("%lld"), "Expected %lld placeholder for percent, got: \(v)")
    }

    func test_installInProgressTemplate_ja_containsJapaneseAndPercentPlaceholder() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "unavail.installInProgress", lang: "ja"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x3040...0x30FF).contains(s) || (0x4E00...0x9FFF).contains(s)
            }),
            "Expected Japanese characters in ja installInProgress template, got: \(v)"
        )
        XCTAssertTrue(v.contains("%lld"), "Expected %lld placeholder, got: \(v)")
    }

    func test_installInProgressTemplate_ar_containsArabic() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "unavail.installInProgress", lang: "ar"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x0600...0x06FF).contains(s)
            }),
            "Expected Arabic characters in ar installInProgress template, got: \(v)"
        )
    }

    func test_installInProgress_en_baselineRuntimeRender() throws {
        // Runtime helper works correctly for .current (which is en on test host).
        let reason = UnavailReason.installInProgress(percent: 50)
        let msg = reason.resolvedDisplayMessage(locale: Locale(identifier: "en"))
        XCTAssertEqual(msg, "installing (50%)")
    }

    // MARK: - unavail.notInstalled

    func test_notInstalledTemplate_ar_containsArabic() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "unavail.notInstalled", lang: "ar"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x0600...0x06FF).contains(s)
            }),
            "Expected Arabic characters in ar notInstalled string, got: \(v)"
        )
    }

    func test_notInstalledTemplate_ru_containsCyrillic() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "unavail.notInstalled", lang: "ru"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x0400...0x04FF).contains(s)
            }),
            "Expected Cyrillic characters in ru notInstalled string, got: \(v)"
        )
    }
}
