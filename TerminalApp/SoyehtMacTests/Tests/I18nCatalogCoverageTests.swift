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

    /// All 17 languages declared in `knownRegions` of the two pbxprojs and
    /// in Packages/SoyehtCore/Package.swift via `.process`.
    private let requiredLocales = [
        "en", "pt-BR", "pt-PT", "es", "de", "fr",
        "ru", "id", "ar", "ur", "ja", "ko", "zh-Hans", "hi",
        "mr", "te", "bn",
    ]

    func test_allCatalogs_complete17Languages_pluralAware() throws {
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
                // Case 2: plural variations. Apple's .xcstrings supports two shapes:
                //   (a) Direct single-arg: plural = { "one": { stringUnit }, "other": { stringUnit }, ... }
                //   (b) Nested multi-arg:  plural = { "arg1": { "variations": { "plural": { "one": ..., "other": ... } } }, ... }
                // Coverage rule: at least the `other` CLDR category must exist with a non-empty value
                // (every locale's CLDR plural rules include `other` as the catch-all). For multi-arg,
                // recurse through each arg's nested variations.
                if let variations = loc["variations"] as? [String: Any],
                   let plural = variations["plural"] as? [String: Any],
                   !plural.isEmpty {
                    if pluralHasOtherCategory(plural) {
                        continue
                    }
                    failures.append(Failure(
                        catalog: catalog.lastPathComponent,
                        key: key,
                        lang: lang,
                        detail: "plural missing non-empty `other` branch"
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

    /// Checks whether a plural block contains a non-empty `other` CLDR category, supporting
    /// both Apple's single-arg (direct `one`/`other` keys) and multi-arg (nested per arg)
    /// plural shapes. The `other` category is required by CLDR for every locale.
    private func pluralHasOtherCategory(_ plural: [String: Any]) -> Bool {
        // Shape (a) — direct: plural = { "other": { stringUnit: { value } } }
        if let other = plural["other"] as? [String: Any],
           let unit = other["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String,
           !value.isEmpty {
            return true
        }
        // Shape (b) — nested per arg: plural = { "arg1": { "variations": { "plural": {...} } }, ... }
        // Every arg must have a reachable `other`. We return true only if all args are satisfied.
        var sawArg = false
        for (_, argRaw) in plural {
            guard let arg = argRaw as? [String: Any] else { return false }
            // If this arg has a nested `variations.plural`, recurse.
            if let nestedVariations = arg["variations"] as? [String: Any],
               let nestedPlural = nestedVariations["plural"] as? [String: Any] {
                if !pluralHasOtherCategory(nestedPlural) {
                    return false
                }
                sawArg = true
                continue
            }
            // If this arg looks like a CLDR category (has stringUnit directly), shape (a) is partial match — handled above.
            return false
        }
        return sawArg
    }
}

// MARK: - Catalog lookup helper (reusable by sibling test targets)

extension I18nCatalogCoverageTests {
    /// Looks up the resolved string value for `key` in `lang` within a `.xcstrings` file.
    /// Returns `nil` if the key is missing or the localization has no resolvable value.
    /// For plural keys, returns the `other` category value (the CLDR catch-all).
    /// Exposed at file scope so `WelcomeTranslationTests`, etc., can reuse it.
    static func lookupCatalogValue(catalog: URL, key: String, lang: String) throws -> String? {
        let data = try Data(contentsOf: catalog)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any],
              let strings = dict["strings"] as? [String: [String: Any]],
              let entry = strings[key],
              let locs = entry["localizations"] as? [String: [String: Any]],
              let loc = locs[lang] else {
            return nil
        }
        if let unit = loc["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        // Plural — return the `other` category value (single-arg direct shape).
        if let variations = loc["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any],
           let other = plural["other"] as? [String: Any],
           let unit = other["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        return nil
    }
}
