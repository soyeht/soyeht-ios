import Foundation

public enum SoyehtFeatureFlags {
    private static let clawStoreDefault = false

    #if DEBUG
    private static let clawStoreOverrideLock = NSLock()
    private nonisolated(unsafe) static var clawStoreEnabledOverride: Bool?
    #endif

    public static var clawStoreEnabled: Bool {
        #if DEBUG
        clawStoreOverrideLock.lock()
        defer { clawStoreOverrideLock.unlock() }
        return clawStoreEnabledOverride ?? clawStoreDefault
        #else
        return clawStoreDefault
        #endif
    }

    #if DEBUG
    public static func setClawStoreEnabledOverride(_ enabled: Bool?) {
        clawStoreOverrideLock.lock()
        defer { clawStoreOverrideLock.unlock() }
        clawStoreEnabledOverride = enabled
    }
    #endif

    public static let onboardingCarouselEnabled = false
}
