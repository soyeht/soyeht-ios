import Testing
@testable import SoyehtCore

@Suite struct ClawDetailActionAvailabilityTests {
    @Test("not installed shows install only when installable and host is ready")
    func notInstalledInstallGate() {
        #expect(actions(.notInstalled).showsInstall)
        #expect(!actions(.notInstalled, installability: .unavailable(reasonCode: .catalogOnly, message: nil)).showsInstall)
        #expect(!actions(.notInstalled, allowsInstall: false).showsInstall)
    }

    @Test("failed install shows retry only when installable and host is ready")
    func failedInstallRetryGate() {
        let failed = ClawInstallState.installFailed(error: "failed")

        #expect(actions(failed).showsRetryInstall)
        #expect(!actions(failed, installability: .unavailable(reasonCode: .noInstallPlan, message: nil)).showsRetryInstall)
        #expect(!actions(failed, allowsInstall: false).showsRetryInstall)
    }

    @Test("installed state offers deploy and uninstall when target supports deploy")
    func installedDeployAndUninstall() {
        let availability = actions(.installed)

        #expect(availability.showsDeploy)
        #expect(availability.showsUninstall)
        #expect(!availability.showsDeployUnavailableNotice)
    }

    @Test("installed state hides deploy when target cannot deploy but keeps uninstall")
    func installedWithoutDeploySupport() {
        let availability = actions(.installed, supportsDeploy: false)

        #expect(!availability.showsDeploy)
        #expect(availability.showsUninstall)
        #expect(availability.showsDeployUnavailableNotice)
    }

    @Test("installed state hides deploy while host preparation gate is active")
    func installedWithHostGateActive() {
        let availability = actions(.installed, allowsInstall: false)

        #expect(!availability.showsDeploy)
        #expect(availability.showsUninstall)
        #expect(!availability.showsDeployUnavailableNotice)
    }

    @Test("installed but blocked can uninstall but cannot deploy")
    func installedButBlockedCanOnlyUninstall() {
        let availability = actions(.installedButBlocked(reasons: [.noColdPathAvailable]))

        #expect(!availability.showsDeploy)
        #expect(availability.showsUninstall)
    }

    @Test("transient and unknown states map to passive indicators")
    func passiveStates() {
        #expect(actions(.installing(nil)).showsInstallingProgress)
        #expect(actions(.uninstalling).showsUninstallingProgress)
        #expect(actions(.unknown).showsUnknownState)
    }

    private func actions(
        _ state: ClawInstallState,
        installability: ClawInstallability = .installable,
        allowsInstall: Bool = true,
        supportsDeploy: Bool = true
    ) -> ClawDetailActionAvailability {
        ClawDetailActionAvailability(
            installState: state,
            installability: installability,
            allowsInstall: allowsInstall,
            supportsDeploy: supportsDeploy
        )
    }
}
