import Foundation

// MARK: - Mock Store Data
// Temporary mock data for ratings, reviews, install counts.
// Will be replaced by real API data when backend adds these fields.

public enum ClawMockData {

    // MARK: - Store Metadata

    public struct ClawStoreInfo: Sendable {
        public let language: String
        public let languageColor: String
        public let rating: Double
        public let ratingStars: String
        public let installCount: String
        public let tagline: String
        public let featured: Bool

        public init(
            language: String,
            languageColor: String,
            rating: Double,
            ratingStars: String,
            installCount: String,
            tagline: String,
            featured: Bool
        ) {
            self.language = language
            self.languageColor = languageColor
            self.rating = rating
            self.ratingStars = ratingStars
            self.installCount = installCount
            self.tagline = tagline
            self.featured = featured
        }
    }

    public static func storeInfo(for clawName: String) -> ClawStoreInfo {
        // Ratings and install counts held at zero for App Store submission;
        // fill in once the backend exposes real telemetry.
        switch clawName.lowercased() {
        case "ironclaw":
            return ClawStoreInfo(
                language: "Rust",
                languageColor: "#DEA584",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Full-featured AI assistant",
                featured: true
            )
        case "picoclaw":
            return ClawStoreInfo(
                language: "Go",
                languageColor: "#00ADD8",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Go-based lightweight claw",
                featured: false
            )
        case "zeroclaw":
            return ClawStoreInfo(
                language: "Rust",
                languageColor: "#DEA584",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Zero-overhead terminal agent",
                featured: false
            )
        case "nullclaw":
            return ClawStoreInfo(
                language: "C",
                languageColor: "#555555",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Inventory monitoring claw",
                featured: false
            )
        case "shadowclaw":
            return ClawStoreInfo(
                language: "Python",
                languageColor: "#3776AB",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Stealth monitoring agent",
                featured: false
            )
        case "byteclaw":
            return ClawStoreInfo(
                language: "Zig",
                languageColor: "#F7A41D",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "Low-level byte manipulation",
                featured: false
            )
        default:
            return ClawStoreInfo(
                language: "Unknown",
                languageColor: "#666666",
                rating: 0.0,
                ratingStars: "",
                installCount: "0",
                tagline: "",
                featured: false
            )
        }
    }

    // MARK: - Reviews

    public struct ClawReview: Sendable {
        public let author: String
        public let rating: Double
        public let text: String
        public let timeAgo: String

        public init(author: String, rating: Double, text: String, timeAgo: String) {
            self.author = author
            self.rating = rating
            self.text = text
            self.timeAgo = timeAgo
        }
    }

    public static func reviews(for clawName: String) -> [ClawReview] {
        return []
    }
}
