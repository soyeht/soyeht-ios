import Foundation

public enum SoyehtFeatureFlags {
    private static let clawStoreDefault = false
    private static let clawStoreE2EDevBundleIdentifiers: Set<String> = [
        "com.soyeht.app.dev",
        "com.soyeht.mac.dev",
    ]
    private static let clawStoreE2ELaunchArgument = "-SoyehtClawStoreE2E"
    private static let clawStoreOverrideLock = NSLock()
    private nonisolated(unsafe) static var clawStoreEnabledOverride: Bool?

    public static var clawStoreEnabled: Bool {
        if isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            return true
        }
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

    @_spi(ClawStoreE2E)
    public static func isClawStoreE2ELaunchArgumentEnabled(
        bundleIdentifier: String?,
        arguments: [String]
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return clawStoreE2EDevBundleIdentifiers.contains(bundleIdentifier)
            && arguments.contains(clawStoreE2ELaunchArgument)
    }

    public static let onboardingCarouselEnabled = false

    @inline(never)
    private static func debugAssertionsEnabled() -> Bool {
        _isDebugAssertConfiguration()
    }
}
