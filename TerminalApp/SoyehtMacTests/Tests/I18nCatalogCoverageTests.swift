import XCTest

/// Parses each `.xcstrings` catalog and asserts that every entry has a
/// non-empty translation (or a valid plural variation) for every required
/// language. Runs off the filesystem — doesn't need app targets or lproj
/// bundles, so it catches coverage drift before the apps are built.
///
/// The coverage test accepts both `translated` and `needs_review` states
/// because a few scripts (mr, te, bn) were seeded by the migration author
/// without native-speaker review; the QA domain doc tracks the follow-up.
final class I18nCatalogCoverageTests: XCTestCase {
    private struct Failure: CustomStringConvertible {
        let catalog: String
        let key: String
        let lang: String
        let detail: String
        var description: String { "[\(catalog)] \(key) / \(lang) → \(detail)" }
    }

    /// All 15 languages declared in `knownRegions` of the two pbxprojs and
    /// in Packages/SoyehtCore/Package.swift via `.process`.
    private let requiredLocales = [
        "en", "pt-BR", "pt-PT", "es", "de", "fr",
        "ru", "id", "ar", "ur", "ja", "hi",
        "mr", "te", "bn",
    ]

    func test_allCatalogs_complete15Languages_pluralAware() throws {
        // #filePath = .../TerminalApp/SoyehtMacTests/Tests/I18nCatalogCoverageTests.swift
        // → up three levels = TerminalApp/
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let repoRoot = terminalApp.deletingLastPathComponent()

        let catalogs = [
            terminalApp.appendingPathComponent("Soyeht/Localizable.xcstrings"),
            terminalApp.appendingPathComponent("SoyehtMac/Localizable.xcstrings"),
            repoRoot.appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings"),
        ]

        var failures: [Failure] = []
        for catalog in catalogs {
            try auditCatalog(catalog, into: &failures)
        }

        XCTAssert(
            failures.isEmpty,
            "\n" + failures.map(\.description).sorted().joined(separator: "\n")
        )
    }

    // MARK: - Helpers

    private func auditCatalog(_ catalog: URL, into failures: inout [Failure]) throws {
        let data = try Data(contentsOf: catalog)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any],
              let strings = dict["strings"] as? [String: [String: Any]] else {
            XCTFail("\(catalog.lastPathComponent) has no `strings` map — is it a valid .xcstrings?")
            return
        }

        for (key, entry) in strings {
            // Entries explicitly flagged `shouldTranslate: false` are exempt
            // (e.g. technical identifiers, brand names). None in the current
            // catalogs, but handled for future additions.
            if (entry["shouldTranslate"] as? Bool) == false { continue }

            let locs = (entry["localizations"] as? [String: [String: Any]]) ?? [:]
            for lang in requiredLocales {
                guard let loc = locs[lang] else {
                    failures.append(Failure(catalog: catalog.lastPathComponent, key: key, lang: lang, detail: "missing localization"))
                    continue
                }
                // Case 1: flat stringUnit.
                if let unit = loc["stringUnit"] as? [String: Any],
                   let state = unit["state"] as? String,
                   let value = unit["value"] as? String,
                   ["translated", "needs_review"].contains(state),
                   !value.isEmpty {
                    continue
                }
                // Case 2: plural variations. Every dimension (arg1, arg2, …)
                // must have at least a non-empty `other` branch.
                if let variations = loc["variations"] as? [String: Any],
                   let plural = variations["plural"] as? [String: Any],
                   !plural.isEmpty {
                    var allDimensionsOK = true
                    var missingDim = ""
                    for (dimName, dimRaw) in plural {
                        guard let dim = dimRaw as? [String: Any],
                              let other = dim["other"] as? [String: Any],
                              let unit = other["stringUnit"] as? [String: Any],
                              let value = unit["value"] as? String,
                              !value.isEmpty else {
                            allDimensionsOK = false
                            missingDim = dimName
                            break
                        }
                    }
                    if allDimensionsOK { continue }
                    failures.append(Failure(
                        catalog: catalog.lastPathComponent,
                        key: key,
                        lang: lang,
                        detail: "plural dim \(missingDim) missing `other`"
                    ))
                    continue
                }
                failures.append(Failure(
                    catalog: catalog.lastPathComponent,
                    key: key,
                    lang: lang,
                    detail: "no stringUnit and no plural variations"
                ))
            }
        }
    }
}
