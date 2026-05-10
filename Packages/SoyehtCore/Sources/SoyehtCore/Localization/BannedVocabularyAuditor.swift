import Foundation

// MARK: - BannedVocabularyViolation

/// A single occurrence of a banned term found in an `.xcstrings` catalog.
public struct BannedVocabularyViolation: Equatable, Sendable {
    public let filePath: String
    public let stringKey: String
    public let locale: String
    public let value: String
    public let matchedTerm: String

    public init(filePath: String, stringKey: String, locale: String, value: String, matchedTerm: String) {
        self.filePath = filePath
        self.stringKey = stringKey
        self.locale = locale
        self.value = value
        self.matchedTerm = matchedTerm
    }

    public var citation: String { "\(filePath):\(stringKey)[\(locale)]" }
}

// MARK: - BannedVocabularyAuditor

/// Scans `.xcstrings` JSON catalogs for banned UI vocabulary (FR-001).
///
/// Banned terms (FR-001):
///   servidor, daemon, theyOS, household, founder, candidate,
///   fingerprint, anchor, pair-machine, pair-device, BIP-39, shard, Shamir
///
/// Usage in CI:
/// ```
/// swift run --package-path Packages/SoyehtCore banned-vocab-audit path/to/Localizable.xcstrings
/// ```
public struct BannedVocabularyAuditor: Sendable {
    /// Canonical banned term list from FR-001.
    public static let bannedTerms: [String] = [
        "servidor",
        "daemon",
        "theyOS",
        "household",
        "founder",
        "candidate",
        "fingerprint",
        "anchor",
        "pair-machine",
        "pair-device",
        "BIP-39",
        "shard",
        "Shamir",
    ]

    private let terms: [String]

    public init(additionalTerms: [String] = []) {
        terms = Self.bannedTerms + additionalTerms
    }

    /// Audits a single `.xcstrings` file.
    /// - Returns: all violations found, empty if clean.
    public func audit(fileURL: URL) throws -> [BannedVocabularyViolation] {
        let data = try Data(contentsOf: fileURL)
        return try audit(data: data, filePath: fileURL.path)
    }

    /// Audits raw `.xcstrings` JSON data.
    public func audit(data: Data, filePath: String) throws -> [BannedVocabularyViolation] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            return []
        }
        var violations: [BannedVocabularyViolation] = []
        for (key, entry) in strings {
            guard let entryMap = entry as? [String: Any],
                  let localizations = entryMap["localizations"] as? [String: Any] else { continue }
            for (locale, locEntry) in localizations {
                let value = extractStringValue(from: locEntry)
                guard let value else { continue }
                for term in terms {
                    if value.localizedCaseInsensitiveContains(term) {
                        violations.append(BannedVocabularyViolation(
                            filePath: filePath,
                            stringKey: key,
                            locale: locale,
                            value: value,
                            matchedTerm: term
                        ))
                        break
                    }
                }
            }
        }
        return violations.sorted { $0.citation < $1.citation }
    }

    /// Audits multiple `.xcstrings` files; aggregates all violations.
    public func auditAll(fileURLs: [URL]) throws -> [BannedVocabularyViolation] {
        try fileURLs.flatMap { try audit(fileURL: $0) }
    }

    // Extracts the `value` string from an xcstrings localization entry.
    // Supports both stringUnit { state, value } and plurals root format.
    private func extractStringValue(from entry: Any) -> String? {
        guard let map = entry as? [String: Any] else { return nil }
        if let unit = map["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        // plurals: check "zero", "one", "other", etc.
        if let variations = map["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any] {
            let forms = ["zero", "one", "two", "few", "many", "other"]
            for form in forms {
                if let formEntry = plural[form] as? [String: Any],
                   let unit = formEntry["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    return value
                }
            }
        }
        return nil
    }
}
