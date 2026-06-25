import Testing
import Foundation

/// Guard: `ClawMockData` must stay CURATION-ONLY. The former fake telemetry
/// (star ratings, written reviews, install counts) was removed from the Store so
/// it never presents fabricated numbers as operational truth. This pins that
/// those symbols cannot quietly return to the source.
@Suite struct ClawMockDataCurationGuardTests {

    @Test("ClawMockData source has no fake-metric symbols (code only)")
    func noFakeMetricSymbols() throws {
        let code = try codeOnly(at: clawMockDataURL())
        let forbidden = ["rating", "ratingStars", "installCount", "ClawReview", "reviews("]
        for token in forbidden {
            #expect(
                !code.contains(token),
                "ClawMockData must stay curation-only; a fake-metric symbol reappeared in code: \(token)"
            )
        }
        // Sanity: the curation surface we DO keep is still present.
        #expect(code.contains("featured"))
    }

    private func clawMockDataURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtCore/ (package root)
            .appendingPathComponent("Sources/SoyehtCore/ClawStore/ClawMockData.swift")
    }

    /// Drops comment-only lines so an explanatory doc comment that names a
    /// removed symbol cannot trip (or satisfy) the invariant.
    private func codeOnly(at url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }
}
