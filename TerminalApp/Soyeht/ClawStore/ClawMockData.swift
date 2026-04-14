import Foundation

// MARK: - Mock Store Data
// Temporary mock data for ratings, reviews, install counts.
// Will be replaced by real API data when backend adds these fields.

enum ClawMockData {

    // MARK: - Store Metadata

    struct ClawStoreInfo {
        let language: String
        let languageColor: String
        let rating: Double
        let ratingStars: String
        let installCount: String
        let tagline: String
        let featured: Bool
    }

    static func storeInfo(for clawName: String) -> ClawStoreInfo {
        // TODO: Replace with real API data when backend adds ratings/reviews.
        // Ratings and install counts commented out for App Store submission.
        switch clawName.lowercased() {
        case "ironclaw":
            return ClawStoreInfo(
                language: "Rust",
                languageColor: "#DEA584",
                rating: 0.0, // 4.9
                ratingStars: "", // "★★★★★"
                installCount: "0", // "2.1k"
                tagline: "Full-featured AI assistant",
                featured: true
            )
        case "picoclaw":
            return ClawStoreInfo(
                language: "Go",
                languageColor: "#00ADD8",
                rating: 0.0, // 4.3
                ratingStars: "", // "★★★★"
                installCount: "0", // "870"
                tagline: "Go-based lightweight claw",
                featured: false
            )
        case "zeroclaw":
            return ClawStoreInfo(
                language: "Rust",
                languageColor: "#DEA584",
                rating: 0.0, // 4.7
                ratingStars: "", // "★★★★★"
                installCount: "0", // "1.4k"
                tagline: "Zero-overhead terminal agent",
                featured: false
            )
        case "nullclaw":
            return ClawStoreInfo(
                language: "C",
                languageColor: "#555555",
                rating: 0.0, // 4.7
                ratingStars: "", // "★★★★"
                installCount: "0", // "460"
                tagline: "Inventory monitoring claw",
                featured: false
            )
        case "shadowclaw":
            return ClawStoreInfo(
                language: "Python",
                languageColor: "#3776AB",
                rating: 0.0, // 4.1
                ratingStars: "", // "★★★★"
                installCount: "0", // "320"
                tagline: "Stealth monitoring agent",
                featured: false
            )
        case "byteclaw":
            return ClawStoreInfo(
                language: "Zig",
                languageColor: "#F7A41D",
                rating: 0.0, // 3.9
                ratingStars: "", // "★★★★"
                installCount: "0", // "180"
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

    struct ClawReview {
        let author: String
        let rating: Double
        let text: String
        let timeAgo: String
    }

    // TODO: Replace with real API data when backend adds reviews.
    // Reviews commented out for App Store submission — uncomment when real data is available.
    static func reviews(for clawName: String) -> [ClawReview] {
        return []
        // switch clawName.lowercased() {
        // case "ironclaw":
        //     return [
        //         ClawReview(
        //             author: "paulo.marcos",
        //             rating: 5.0,
        //             text: "I use it daily on the server. It has not failed once in 6 months. Outstanding performance compared with other claws.",
        //             timeAgo: "2 weeks ago"
        //         ),
        //         ClawReview(
        //             author: "dev_ricardo",
        //             rating: 5.0,
        //             text: "Perfect for complex automations. The best claw I have used so far. It replaced 3 tools I used before.",
        //             timeAgo: "1 month ago"
        //         ),
        //         ClawReview(
        //             author: "ana.silva",
        //             rating: 4.0,
        //             text: "Very good, but Python support could be better. Aside from that, it is excellent in the terminal.",
        //             timeAgo: "2 months ago"
        //         ),
        //     ]
        // case "picoclaw":
        //     return [
        //         ClawReview(
        //             author: "joao.dev",
        //             rating: 4.5,
        //             text: "Fast and pragmatic. Does exactly what you need without the bloat.",
        //             timeAgo: "1 week ago"
        //         ),
        //         ClawReview(
        //             author: "maria.ops",
        //             rating: 4.0,
        //             text: "Great for quick tasks. Lighter than ironclaw but still capable.",
        //             timeAgo: "3 weeks ago"
        //         ),
        //     ]
        // case "zeroclaw":
        //     return [
        //         ClawReview(
        //             author: "lucas.sys",
        //             rating: 5.0,
        //             text: "Zero overhead is real. Barely touches RAM even under heavy load.",
        //             timeAgo: "5 days ago"
        //         ),
        //     ]
        // case "nullclaw":
        //     return [
        //         ClawReview(
        //             author: "pedro.admin",
        //             rating: 4.5,
        //             text: "Pure command, zero waste. Perfect for inventory monitoring.",
        //             timeAgo: "2 weeks ago"
        //         ),
        //     ]
        // default:
        //     return []
        // }
    }

}
