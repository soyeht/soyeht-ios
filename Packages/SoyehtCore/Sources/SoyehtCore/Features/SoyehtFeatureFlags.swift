import Foundation

public enum SoyehtFeatureFlags {
    private static let clawStoreDefault = false
    private static let e2eDevBundleIdentifiers: Set<String> = [
        "com.soyeht.app.dev",
        "com.soyeht.mac.dev",
    ]
    private static let clawStoreE2ELaunchArgument = "-SoyehtClawStoreE2E"
    private static let mobileClawVPNControlPlaneDefault = false
    private static let mobileClawVPNControlPlaneE2ELaunchArgument = "-SoyehtMobileClawVPNControlPlaneE2E"
    private static let persistentLocalPanesDefault = false
    private static let persistentLocalPanesE2ELaunchArgument = "-SoyehtPersistentLocalPanesE2E"
    private static let clawStoreOverrideLock = NSLock()
    private static let mobileClawVPNControlPlaneOverrideLock = NSLock()
    private static let persistentLocalPanesOverrideLock = NSLock()
    private nonisolated(unsafe) static var clawStoreEnabledOverride: Bool?
    private nonisolated(unsafe) static var mobileClawVPNControlPlaneEnabledOverride: Bool?
    private nonisolated(unsafe) static var persistentLocalPanesEnabledOverride: Bool?

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

    public static var mobileClawVPNControlPlaneEnabled: Bool {
        if isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            return true
        }
        guard debugAssertionsEnabled() else {
            return mobileClawVPNControlPlaneDefault
        }
        mobileClawVPNControlPlaneOverrideLock.lock()
        defer { mobileClawVPNControlPlaneOverrideLock.unlock() }
        return mobileClawVPNControlPlaneEnabledOverride ?? mobileClawVPNControlPlaneDefault
    }

    /// Routes a local agent pane (bash/claude/codex/opencode spawned by this
    /// app) through the engine's broker-owned PTY (`POST
    /// /api/v1/terminals/local`) instead of a direct `NativePTY` forkpty, so
    /// the pane survives an app restart/update. `NativePTY` remains the
    /// fallback when this is off (default) or when engine attach fails.
    public static var persistentLocalPanesEnabled: Bool {
        if isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            return true
        }
        guard debugAssertionsEnabled() else {
            return persistentLocalPanesDefault
        }
        persistentLocalPanesOverrideLock.lock()
        defer { persistentLocalPanesOverrideLock.unlock() }
        return persistentLocalPanesEnabledOverride ?? persistentLocalPanesDefault
    }

    @_spi(ClawStoreE2E)
    public static func setPersistentLocalPanesEnabledOverride(_ enabled: Bool?) {
        guard debugAssertionsEnabled() else {
            return
        }
        persistentLocalPanesOverrideLock.lock()
        defer { persistentLocalPanesOverrideLock.unlock() }
        persistentLocalPanesEnabledOverride = enabled
    }

    @_spi(ClawStoreE2E)
    public static func isPersistentLocalPanesE2ELaunchArgumentEnabled(
        bundleIdentifier: String?,
        arguments: [String]
    ) -> Bool {
        // Same release safety model as Claw Store E2E: optimized Dev builds may
        // still opt in, but only through an allowed development bundle plus an
        // explicit launch argument.
        guard let bundleIdentifier else { return false }
        return e2eDevBundleIdentifiers.contains(bundleIdentifier)
            && arguments.contains(persistentLocalPanesE2ELaunchArgument)
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
    public static func setMobileClawVPNControlPlaneEnabledOverride(_ enabled: Bool?) {
        guard debugAssertionsEnabled() else {
            return
        }
        mobileClawVPNControlPlaneOverrideLock.lock()
        defer { mobileClawVPNControlPlaneOverrideLock.unlock() }
        mobileClawVPNControlPlaneEnabledOverride = enabled
    }

    @_spi(ClawStoreE2E)
    public static func isClawStoreE2ELaunchArgumentEnabled(
        bundleIdentifier: String?,
        arguments: [String]
    ) -> Bool {
        // This path intentionally does not depend on debug assertions: Xcode can
        // compile SoyehtCore optimized inside the Dev app. Shipping safety comes
        // from the explicit dev-bundle allowlist plus the launch argument.
        guard let bundleIdentifier else { return false }
        return e2eDevBundleIdentifiers.contains(bundleIdentifier)
            && arguments.contains(clawStoreE2ELaunchArgument)
    }

    @_spi(ClawStoreE2E)
    public static func isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
        bundleIdentifier: String?,
        arguments: [String]
    ) -> Bool {
        // Same release safety model as Claw Store E2E: optimized Dev builds may
        // still opt in, but only through an allowed development bundle plus an
        // explicit launch argument.
        guard let bundleIdentifier else { return false }
        return e2eDevBundleIdentifiers.contains(bundleIdentifier)
            && arguments.contains(mobileClawVPNControlPlaneE2ELaunchArgument)
    }

    public static let onboardingCarouselEnabled = false

    @inline(never)
    private static func debugAssertionsEnabled() -> Bool {
        _isDebugAssertConfiguration()
    }
}
