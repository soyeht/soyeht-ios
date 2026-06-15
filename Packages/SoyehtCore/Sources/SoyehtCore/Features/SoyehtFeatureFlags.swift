import Foundation

public enum SoyehtFeatureFlags {
    private static let clawStoreDefault = false
    private static let clawStoreOverrideLock = NSLock()
    private nonisolated(unsafe) static var clawStoreEnabledOverride: Bool?

    public static var clawStoreEnabled: Bool {
        guard debugAssertionsEnabled() else {
            return clawStoreDefault
        }
        clawStoreOverrideLock.lock()
        defer { clawStoreOverrideLock.unlock() }
        return clawStoreEnabledOverride ?? clawStoreDefault
    }

    @_spi(ClawStoreE2E)
    public static func setClawStoreEnabledOverride(_ enabled: Bool?) {
        guard debugAssertionsEnabled() else {
            return
        }
        clawStoreOverrideLock.lock()
        defer { clawStoreOverrideLock.unlock() }
        clawStoreEnabledOverride = enabled
    }

    public static let onboardingCarouselEnabled = false

    @inline(never)
    private static func debugAssertionsEnabled() -> Bool {
        _isDebugAssertConfiguration()
    }
}
