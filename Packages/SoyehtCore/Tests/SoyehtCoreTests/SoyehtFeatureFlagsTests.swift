import Testing
@_spi(ClawStoreE2E) import SoyehtCore

@Suite("SoyehtFeatureFlags", .serialized)
struct SoyehtFeatureFlagsTests {
    @Test func clawStoreIsDisabledByDefault() {
        SoyehtFeatureFlags.setClawStoreEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.clawStoreEnabled == false)
    }

    @Test func clawStoreOverrideEnablesAndClears() {
        SoyehtFeatureFlags.setClawStoreEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setClawStoreEnabledOverride(nil) }

        SoyehtFeatureFlags.setClawStoreEnabledOverride(true)
        #expect(SoyehtFeatureFlags.clawStoreEnabled == _isDebugAssertConfiguration())

        SoyehtFeatureFlags.setClawStoreEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.clawStoreEnabled == false)
    }

    @Test func falseOverrideKeepsClawStoreDisabled() {
        SoyehtFeatureFlags.setClawStoreEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setClawStoreEnabledOverride(nil) }

        SoyehtFeatureFlags.setClawStoreEnabledOverride(false)
        #expect(SoyehtFeatureFlags.clawStoreEnabled == false)
    }

    @Test func e2eLaunchArgumentOnlyEnablesDevBundle() {
        #expect(SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht"]
        ))
    }
}
