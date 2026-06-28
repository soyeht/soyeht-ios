@testable import SoyehtMacDomain
import SoyehtCore
import XCTest

final class DevEmbeddedEngineSmokeTests: XCTestCase {

    func test_gateIsInertWithoutOptInEnvironment() {
        let decision = DevEmbeddedEngineSmokeGate.decision(
            environment: [:],
            bundleIdentifier: "com.soyeht.mac.dev",
            profile: .dev
        )

        XCTAssertEqual(decision, .notRequested)
    }

    func test_gateRefusesReleaseProfileEvenWhenOptedIn() {
        let decision = DevEmbeddedEngineSmokeGate.decision(
            environment: [DevEmbeddedEngineSmokeGate.runEnvKey: "1"],
            bundleIdentifier: "com.soyeht.mac",
            profile: .release
        )

        XCTAssertEqual(decision, .refused(reason: "install_profile_not_dev"))
    }

    func test_gateRefusesNonDevBundleIdentifierEvenForDevProfile() {
        let decision = DevEmbeddedEngineSmokeGate.decision(
            environment: [DevEmbeddedEngineSmokeGate.runEnvKey: "1"],
            bundleIdentifier: "com.soyeht.mac",
            profile: .dev
        )

        XCTAssertEqual(decision, .refused(reason: "bundle_identifier_not_dev"))
    }

    func test_gateRunsOnlyForDevBundleAndDevProfile() {
        let decision = DevEmbeddedEngineSmokeGate.decision(
            environment: [DevEmbeddedEngineSmokeGate.runEnvKey: "1"],
            bundleIdentifier: DevEmbeddedEngineSmokeGate.requiredBundleIdentifier,
            profile: .dev
        )

        XCTAssertEqual(decision, .run)
    }

    func test_localAppleCaptureGateIsInertWithoutOptInEnvironment() {
        let decision = DevLocalAppleAttestationCaptureGate.decision(
            environment: [:],
            bundleIdentifier: DevLocalAppleAttestationCaptureGate.requiredBundleIdentifier,
            profile: .dev
        )

        XCTAssertEqual(decision, .notRequested)
    }

    func test_localAppleCaptureGateRefusesShippingProfile() {
        let decision = DevLocalAppleAttestationCaptureGate.decision(
            environment: [
                DevLocalAppleAttestationCaptureGate.runEnvKey: "1",
                DevLocalAppleAttestationCaptureGate.fixtureEnvKey: "/tmp/fixture.json",
            ],
            bundleIdentifier: "com.soyeht.mac",
            profile: .release
        )

        XCTAssertEqual(decision, .refused(reason: "install_profile_not_dev"))
    }

    func test_localAppleCaptureGateRequiresExplicitFixturePath() {
        let decision = DevLocalAppleAttestationCaptureGate.decision(
            environment: [DevLocalAppleAttestationCaptureGate.runEnvKey: "1"],
            bundleIdentifier: DevLocalAppleAttestationCaptureGate.requiredBundleIdentifier,
            profile: .dev
        )

        XCTAssertEqual(decision, .refused(reason: "fixture_path_missing"))
    }

    func test_localAppleCaptureGateRefusesResultPathEqualToFixturePath() {
        let decision = DevLocalAppleAttestationCaptureGate.decision(
            environment: [
                DevLocalAppleAttestationCaptureGate.runEnvKey: "1",
                DevLocalAppleAttestationCaptureGate.fixtureEnvKey: "/tmp/fixture.json",
                DevLocalAppleAttestationCaptureGate.resultEnvKey: "/tmp/fixture.json",
            ],
            bundleIdentifier: DevLocalAppleAttestationCaptureGate.requiredBundleIdentifier,
            profile: .dev
        )

        XCTAssertEqual(decision, .refused(reason: "result_path_matches_fixture_path"))
    }

    func test_localAppleCaptureGateRunsOnlyForDevBundleDevProfileAndFixturePath() {
        let decision = DevLocalAppleAttestationCaptureGate.decision(
            environment: [
                DevLocalAppleAttestationCaptureGate.runEnvKey: "1",
                DevLocalAppleAttestationCaptureGate.fixtureEnvKey: "/tmp/fixture.json",
            ],
            bundleIdentifier: DevLocalAppleAttestationCaptureGate.requiredBundleIdentifier,
            profile: .dev
        )

        XCTAssertEqual(decision, .run(fixturePath: "/tmp/fixture.json"))
    }

    func test_probeValidatesFakeDevBundleAgainstInstallProfileSpec() throws {
        let bundle = try FakeEmbeddedEngineBundle.make(profile: .dev)
        defer { bundle.cleanup() }

        let result = try EmbeddedEngineBundleProbe(
            bundleURL: bundle.bundleURL,
            profile: .dev
        ).validateBundledSupport()

        XCTAssertEqual(result.profileKind, .dev)
        XCTAssertEqual(result.plistName, SoyehtInstallProfile.dev.engineLaunchAgentPlistName)
        XCTAssertEqual(result.launchdLabel, SoyehtInstallProfile.dev.engineLaunchdLabel)
        XCTAssertEqual(result.bundledHelperCount, EmbeddedEngineSupportBundleSpec.supportBinaryNames.count)
    }

    func test_probeRejectsMissingBundledHelper() throws {
        let bundle = try FakeEmbeddedEngineBundle.make(profile: .dev)
        defer { bundle.cleanup() }

        let helperURL = bundle.helpersDirectory
            .appendingPathComponent(EmbeddedEngineSupportBundleSpec.supportBinaryNames[0])
        try FileManager.default.removeItem(at: helperURL)

        XCTAssertThrowsError(
            try EmbeddedEngineBundleProbe(bundleURL: bundle.bundleURL, profile: .dev).validateBundledSupport()
        ) { error in
            XCTAssertEqual(
                error as? EmbeddedEngineBundleProbeError,
                .missingBundledHelper(EmbeddedEngineSupportBundleSpec.supportBinaryNames[0])
            )
        }
    }

    func test_probeRejectsLaunchAgentLabelDrift() throws {
        let bundle = try FakeEmbeddedEngineBundle.make(profile: .dev, launchdLabel: "com.soyeht.engine")
        defer { bundle.cleanup() }

        XCTAssertThrowsError(
            try EmbeddedEngineBundleProbe(bundleURL: bundle.bundleURL, profile: .dev).validateBundledSupport()
        ) { error in
            XCTAssertEqual(
                error as? EmbeddedEngineBundleProbeError,
                .launchAgentLabelMismatch(
                    expected: SoyehtInstallProfile.dev.engineLaunchdLabel,
                    actual: "com.soyeht.engine"
                )
            )
        }
    }

    func test_appDelegateHooksSmokeBeforeNormalLaunchWork() throws {
        let source = try String(contentsOf: appDelegateSourceURL(), encoding: .utf8)
        let hook = try XCTUnwrap(source.range(of: "DevEmbeddedEngineSmokeRunner.startIfRequested()"))
        let firstNormalLaunchWork = try XCTUnwrap(source.range(of: "AppEnvironment.workspaceStore = workspaceStore"))

        XCTAssertLessThan(hook.lowerBound, firstNormalLaunchWork.lowerBound)
        XCTAssertTrue(source.contains("#if DEBUG\n        if DevEmbeddedEngineSmokeRunner.startIfRequested()"))
    }

    func test_appDelegateHooksLocalAppleCaptureBeforeNormalLaunchWork() throws {
        let source = try String(contentsOf: appDelegateSourceURL(), encoding: .utf8)
        let hook = try XCTUnwrap(
            source.range(of: "DevLocalAppleAttestationCaptureRunner.startIfRequested()")
        )
        let firstNormalLaunchWork = try XCTUnwrap(source.range(of: "AppEnvironment.workspaceStore = workspaceStore"))

        XCTAssertLessThan(hook.lowerBound, firstNormalLaunchWork.lowerBound)
        XCTAssertTrue(source.contains("if DevLocalAppleAttestationCaptureRunner.startIfRequested()"))
    }

    func test_localAppleCaptureRunnerStopsBeforeFinishAndShippingApp() throws {
        let source = try String(contentsOf: appDelegateSourceURL(), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private enum DevLocalAppleAttestationCaptureRunner"))
        let segment = source[start.lowerBound...]

        XCTAssertTrue(segment.contains("startMacosLocalAttested()"))
        XCTAssertTrue(segment.contains("provider.register(request)"))
        XCTAssertTrue(segment.contains("fixture.write"))
        XCTAssertFalse(segment.contains("registration/local/finish"))
        XCTAssertFalse(segment.contains("macosLocalAttestedFinish"))
        XCTAssertFalse(segment.contains("/Applications/Soyeht.app"))
    }

    func test_scriptIsDefaultInert() throws {
        let source = try String(contentsOf: smokeScriptURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("SOYEHT_RUN_DEV_ENGINE_SMOKE"))
        XCTAssertTrue(source.contains("SOYEHT_RUN_DEV_ENGINE_SMOKE_not_set"))
        XCTAssertTrue(source.contains("shipping_app_bundle_refused"))
        XCTAssertFalse(source.contains("launchctl"))
        XCTAssertFalse(source.contains("com.soyeht.engine\""))
    }

    private func appDelegateSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .appendingPathComponent("SoyehtMac/AppDelegate.swift")
    }

    private func smokeScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/dev-embedded-engine-smoke.sh")
    }
}

private struct FakeEmbeddedEngineBundle {
    let rootURL: URL
    let bundleURL: URL
    let helpersDirectory: URL

    static func make(
        profile: SoyehtInstallProfile,
        launchdLabel: String? = nil,
        fileManager: FileManager = .default
    ) throws -> FakeEmbeddedEngineBundle {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("soyeht-dev-engine-smoke-tests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("Soyeht Dev.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersDirectory = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let launchAgentsDirectory = contentsURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)

        try fileManager.createDirectory(at: helpersDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        for helper in EmbeddedEngineSupportBundleSpec.supportBinaryNames {
            let url = helpersDirectory.appendingPathComponent(helper, isDirectory: false)
            XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: Data("stub".utf8)))
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path
            )
        }

        let spec = EmbeddedEngineLaunchAgentSpec(profile: profile)
        let plist: [String: Any] = [
            "Label": launchdLabel ?? spec.launchdLabel,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: launchAgentsDirectory.appendingPathComponent(spec.plistName, isDirectory: false),
            options: .atomic
        )

        return FakeEmbeddedEngineBundle(
            rootURL: rootURL,
            bundleURL: bundleURL,
            helpersDirectory: helpersDirectory
        )
    }

    func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: rootURL)
    }
}
