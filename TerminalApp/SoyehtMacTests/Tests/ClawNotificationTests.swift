import XCTest
import UserNotifications
import SoyehtCore

/// Validates the localized notification strings for `ClawNotificationHelper` across locales
/// (ST-Q-I18N-006). Uses two complementary approaches:
///
///   1. **JSON-level catalog assertions** — verify that the SoyehtCore `Localizable.xcstrings`
///      contains the expected translations for every supported locale. This is reliable in
///      SPM test context (where xcstrings is shipped raw, without per-locale `.lproj` folders
///      compiled into Bundle.module).
///
///   2. **Runtime helper smoke test** (en baseline only) — call
///      `ClawNotificationHelper.makeInstallCompleteContent` in the default locale and verify
///      the composed content interpolates the claw name correctly. Non-English locale
///      resolution at runtime is validated indirectly via the catalog assertions; it works
///      correctly in xcodebuild-built app contexts (which compile xcstrings into `.lproj`
///      subfolders inside the app bundle), which the iOS `I18nSmokeTests` already covers.
final class ClawNotificationTests: XCTestCase {

    private var coreCatalog: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings")
    }

    // MARK: - JSON-level catalog assertions (ST-Q-I18N-006 core)

    func test_installSuccessTitle_ja_containsJapaneseInstallMarker() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "notify.claw.install.success.title", lang: "ja"))
        XCTAssertTrue(v.contains("インストール"), "Expected Japanese 'install' (インストール) in ja template, got: \(v)")
        XCTAssertTrue(v.contains("%@"), "Expected %@ placeholder for claw name, got: \(v)")
    }

    func test_installSuccessTitle_ar_containsArabicCharacters() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "notify.claw.install.success.title", lang: "ar"))
        XCTAssertTrue(
            v.contains(where: { c in
                let s = c.unicodeScalars.first!.value
                return (0x0600...0x06FF).contains(s)
            }),
            "Expected Arabic characters in ar install-success title, got: \(v)"
        )
        XCTAssertTrue(v.contains("%@"), "Expected %@ placeholder, got: \(v)")
    }

    func test_installSuccessTitle_fr_containsInstalleStem() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "notify.claw.install.success.title", lang: "fr"))
        XCTAssertTrue(v.lowercased().contains("install"), "Expected French 'install*' stem in title, got: \(v)")
    }

    func test_installFailureTitle_pt_BR_containsFalhaOrErro() throws {
        let v = try XCTUnwrap(I18nCatalogCoverageTests.lookupCatalogValue(catalog: coreCatalog, key: "notify.claw.install.failure.title", lang: "pt-BR"))
        let lower = v.lowercased()
        XCTAssertTrue(
            lower.contains("falh") || lower.contains("erro") || lower.contains("falhou"),
            "Expected pt-BR failure keyword (falha/falhou/erro) in title, got: \(v)"
        )
    }

    // MARK: - Runtime helper smoke (en baseline only)

    func test_runtime_installSuccess_en_baselineInterpolation() throws {
        let content = ClawNotificationHelper.makeInstallCompleteContent(
            clawName: "angel-claw",
            success: true,
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(content.title, "angel-claw installed")
        XCTAssertEqual(content.body, "angel-claw is ready to deploy")
    }
}
