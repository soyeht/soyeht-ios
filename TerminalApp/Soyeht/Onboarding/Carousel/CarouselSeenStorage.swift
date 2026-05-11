import SwiftUI
import SoyehtCore

/// Persists the carousel-seen timestamp (T087, FR-021).
/// `seenAt == nil` means the user has never completed the tour.
/// Short-circuits automatically for restored-from-backup launches (FR-122).
struct CarouselSeenStorage {
    @AppStorage("carousel_seen_at") private var seenAtInterval: Double = 0

    var seenAt: Date? {
        get { seenAtInterval > 0 ? Date(timeIntervalSince1970: seenAtInterval) : nil }
        nonmutating set { seenAtInterval = newValue.map(\.timeIntervalSince1970) ?? 0 }
    }

    var shouldShowCarousel: Bool {
        // Restored-from-backup users skip the carousel (FR-122).
        shouldShowCarousel(restoredFromBackup: RestoredFromBackupDetector().detect())
    }

    func shouldShowCarousel(restoredFromBackup: Bool) -> Bool {
        if restoredFromBackup { return false }
        return seenAt == nil
    }

    func markSeen() {
        seenAt = Date()
    }

    func clearSeen() {
        seenAt = nil
    }
}
