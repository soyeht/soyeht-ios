import Foundation

/// Detects whether the current app launch is a true first-install or a
/// restore from iCloud backup (research R18, FR-122).
///
/// Uses `NSUbiquitousKeyValueStore` to persist a `first_launch_completed_at`
/// timestamp. The key survives iCloud backup/restore and wipe+reinstall from
/// the same Apple ID; it does NOT survive a fresh Apple ID.
///
/// Call `detect()` once at app startup, before showing any UI.
public struct RestoredFromBackupDetector {
    static let kvKey = "soyeht.first_launch_completed_at"
    static let localKey = "soyeht.first_launch_completed_local_at"

    private let kvStore: NSUbiquitousKeyValueStore

    public init(kvStore: NSUbiquitousKeyValueStore = .default) {
        self.kvStore = kvStore
    }

    /// Returns `true` if a prior first-launch timestamp was found in iCloud KV —
    /// implying this is a restore. Writes the timestamp on the true first-launch path.
    ///
    /// - Note: Call `kvStore.synchronize()` before this if you need the most
    ///   recent iCloud state (network availability permitting).
    public func detect() -> Bool {
        kvStore.synchronize()

        let cloudSeen = kvStore.object(forKey: Self.kvKey) != nil
        let localSeen = UserDefaults.standard.object(forKey: Self.localKey) != nil

        if cloudSeen && !localSeen {
            UserDefaults.standard.set(Date(), forKey: Self.localKey)
            return true
        }

        if !cloudSeen {
            kvStore.set(Date(), forKey: Self.kvKey)
            kvStore.synchronize()
        }

        if !localSeen {
            UserDefaults.standard.set(Date(), forKey: Self.localKey)
        }

        return false
    }

    /// Clears the stored timestamp — for testing or "Recomeçar do zero" (FR-061).
    public func reset() {
        kvStore.removeObject(forKey: Self.kvKey)
        kvStore.synchronize()
        UserDefaults.standard.removeObject(forKey: Self.localKey)
    }
}
