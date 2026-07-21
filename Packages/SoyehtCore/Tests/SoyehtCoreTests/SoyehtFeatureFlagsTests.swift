import Testing
@_spi(ClawStoreE2E) import SoyehtCore

@Suite("SoyehtFeatureFlags", .serialized)
struct SoyehtFeatureFlagsTests {
    @Test func clawStoreIsDisabledByDefault() {
        SoyehtFeatureFlags.setClawStoreEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.clawStoreEnabled == false)
    }

    @Test func mobileClawVPNControlPlaneIsDisabledByDefault() {
        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled == false)
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

    @Test func mobileClawVPNControlPlaneOverrideEnablesAndClears() {
        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil) }

        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(true)
        #expect(SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled == _isDebugAssertConfiguration())

        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled == false)
    }

    @Test func falseOverrideKeepsMobileClawVPNControlPlaneDisabled() {
        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(nil) }

        SoyehtFeatureFlags.setMobileClawVPNControlPlaneEnabledOverride(false)
        #expect(SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled == false)
    }

    @Test func e2eLaunchArgumentOnlyEnablesAllowedDevBundles() {
        #expect(SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac",
            arguments: ["Soyeht", "-SoyehtClawStoreE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht"]
        ))
        #expect(!SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht"]
        ))
    }

    @Test func persistentLocalPanesIsEnabledByDefault() {
        // Shipped default since mac-v0.1.30 (engine >= 0.1.22 bundles the
        // local broker).
        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.persistentLocalPanesEnabled == true)
    }

    @Test func persistentLocalPanesOverrideEnablesAndClears() {
        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil) }

        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(true)
        #expect(SoyehtFeatureFlags.persistentLocalPanesEnabled == true)

        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil)
        #expect(SoyehtFeatureFlags.persistentLocalPanesEnabled == true)
    }

    @Test func falseOverrideDisablesPersistentLocalPanesInDebugOnly() {
        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil)
        defer { SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(nil) }

        // Debug builds honor the false override; release builds ignore
        // overrides entirely and pin to the shipped default (true).
        SoyehtFeatureFlags.setPersistentLocalPanesEnabledOverride(false)
        #expect(SoyehtFeatureFlags.persistentLocalPanesEnabled == !_isDebugAssertConfiguration())
    }

    @Test func persistentLocalPanesE2ELaunchArgumentOnlyEnablesAllowedDevBundles() {
        #expect(SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht", "-SoyehtPersistentLocalPanesE2E"]
        ))
        #expect(SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht", "-SoyehtPersistentLocalPanesE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app",
            arguments: ["Soyeht", "-SoyehtPersistentLocalPanesE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac",
            arguments: ["Soyeht", "-SoyehtPersistentLocalPanesE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht"]
        ))
        #expect(!SoyehtFeatureFlags.isPersistentLocalPanesE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht"]
        ))
    }

    @Test func mobileClawVPNControlPlaneE2ELaunchArgumentOnlyEnablesAllowedDevBundles() {
        #expect(SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht", "-SoyehtMobileClawVPNControlPlaneE2E"]
        ))
        #expect(SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht", "-SoyehtMobileClawVPNControlPlaneE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app",
            arguments: ["Soyeht", "-SoyehtMobileClawVPNControlPlaneE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac",
            arguments: ["Soyeht", "-SoyehtMobileClawVPNControlPlaneE2E"]
        ))
        #expect(!SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.app.dev",
            arguments: ["Soyeht"]
        ))
        #expect(!SoyehtFeatureFlags.isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled(
            bundleIdentifier: "com.soyeht.mac.dev",
            arguments: ["Soyeht"]
        ))
    }
}
