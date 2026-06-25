import Foundation

// MARK: - Store Curation
//
// Editor's-pick curation for the Claw Store. This is intentionally NOT telemetry:
// the former fake-metric placeholders were removed so the Store never presents
// fabricated numbers as operational truth. Only curation (which claw is
// "featured") lives here until a real backend source exists. The type keeps its
// `ClawMockData` name for now to minimize churn; a rename to a curation-specific
// type is a separate follow-up.

public enum ClawMockData {

    // MARK: - Store Metadata (curation only)

    public struct ClawStoreInfo: Sendable {
        public let featured: Bool

        public init(featured: Bool) {
            self.featured = featured
        }
    }

    public static func storeInfo(for clawName: String) -> ClawStoreInfo {
        switch clawName.lowercased() {
        case "ironclaw":
            return ClawStoreInfo(featured: true)
        default:
            return ClawStoreInfo(featured: false)
        }
    }
}
