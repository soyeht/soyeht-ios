import Testing
@testable import SoyehtCore

@Suite struct ClawActionPolicyTests {

    // MARK: - Rule table, exhaustive over the input cross-product

    @Test("rule table holds for every state x installability x readiness x deploy x in-flight x terminal")
    func ruleTableInvariants() {
        let states: [ClawInstallState] = [
            .notInstalled,
            .installing(nil),
            .uninstalling,
            .installed,
            .installedButBlocked(reasons: []),
            .installFailed(error: "e"),
            .unknown,
        ]
        let installabilities: [ClawInstallability] = [
            .installable,
            .unavailable(reasonCode: .catalogOnly, message: "m"),
            .unavailable(reasonCode: .noInstallPlan, message: nil),
        ]
        let bools = [true, false]

        for state in states {
            for inst in installabilities {
                for hostAllows in bools {
                    for supportsDeploy in bools {
                        for inFlight in bools {
                            for canTerm in bools {
                                let p = policy(
                                    state,
                                    installability: inst,
                                    hostAllowsInstall: hostAllows,
                                    supportsDeploy: supportsDeploy,
                                    actionInFlight: inFlight,
                                    canOpenTerminal: canTerm
                                )
                                let installable = inst.isInstallable
                                let uninstallVisible = stateIsInstalled(state) || stateIsInstalledButBlocked(state)

                                // install
                                #expect(p.isVisible(.install) == (stateIsNotInstalled(state) && installable))
                                #expect(p.isEnabled(.install) == (stateIsNotInstalled(state) && installable && hostAllows && !inFlight))
                                // retryInstall
                                #expect(p.isVisible(.retryInstall) == (stateIsInstallFailed(state) && installable))
                                #expect(p.isEnabled(.retryInstall) == (stateIsInstallFailed(state) && installable && hostAllows && !inFlight))
                                // deploy
                                #expect(p.isVisible(.deploy) == (stateIsInstalled(state) && supportsDeploy))
                                #expect(p.isEnabled(.deploy) == (stateIsInstalled(state) && supportsDeploy && hostAllows && !inFlight))
                                // openTerminal - rides on deploy visibility, gated by canOpenTerminal AND in-flight (NOT readiness)
                                #expect(p.isVisible(.openTerminal) == (stateIsInstalled(state) && supportsDeploy))
                                #expect(p.isEnabled(.openTerminal) == (stateIsInstalled(state) && supportsDeploy && canTerm && !inFlight))
                                // uninstall - never gated by readiness/installability, only by in-flight
                                #expect(p.isVisible(.uninstall) == uninstallVisible)
                                #expect(p.isEnabled(.uninstall) == (uninstallVisible && !inFlight))
                                // transient
                                if stateIsInstalling(state) {
                                    #expect(p.transient == .installing)
                                } else if stateIsUninstalling(state) {
                                    #expect(p.transient == .uninstalling)
                                } else {
                                    #expect(p.transient == nil)
                                }
                                // unknown passive
                                #expect(p.showsUnknownState == stateIsUnknown(state))
                                // deploy-unavailable notice mirrors the legacy rule exactly
                                #expect((p.deployUnavailableReason != nil) == (!supportsDeploy && state.isInstalled))
                                // mayIssueInstall ignores in-flight
                                #expect(p.mayIssueInstall == (installable && hostAllows && (stateIsNotInstalled(state) || stateIsInstallFailed(state))))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Block reasons

    @Test("block reasons explain hidden vs disabled install")
    func blockReasonsExplainInstall() {
        let notInstallable = policy(.notInstalled, installability: .unavailable(reasonCode: .catalogOnly, message: "m"))
        #expect(!notInstallable.isVisible(.install))
        #expect(notInstallable.blockReason(for: .install) == .notInstallable(.catalogOnly, message: "m"))

        let notReady = policy(.notInstalled, hostAllowsInstall: false)
        #expect(notReady.isVisible(.install) && !notReady.isEnabled(.install))
        #expect(notReady.blockReason(for: .install) == .hostNotReady)

        let inFlight = policy(.notInstalled, actionInFlight: true)
        #expect(inFlight.isVisible(.install) && !inFlight.isEnabled(.install))
        #expect(inFlight.blockReason(for: .install) == .actionInFlight)
    }

    @Test("deploy unsupported target reports a reason for the inline notice")
    func deployUnsupportedReason() {
        let p = policy(.installed, supportsDeploy: false)
        #expect(!p.isVisible(.deploy))
        #expect(p.blockReason(for: .deploy) == .deployUnsupportedForTarget)
        #expect(p.deployUnavailableReason == .deployUnsupportedForTarget)
    }

    @Test("installBlockedReason summarizes the install gate independent of state")
    func installBlockedReasonSummary() {
        #expect(policy(.notInstalled).installBlockedReason == nil)
        #expect(policy(.notInstalled, hostAllowsInstall: false).installBlockedReason == .hostNotReady)
        #expect(policy(.notInstalled, installability: .unavailable(reasonCode: .noInstallPlan, message: nil)).installBlockedReason == .notInstallable(.noInstallPlan, message: nil))
        #expect(policy(.notInstalled, actionInFlight: true).installBlockedReason == .actionInFlight)
    }

    @Test("openTerminal respects actionInFlight like every other shown action")
    func openTerminalRespectsInFlight() {
        // installed + supportsDeploy + canOpenTerminal + actionInFlight => visible but disabled (.actionInFlight)
        let inFlight = policy(.installed, supportsDeploy: true, actionInFlight: true, canOpenTerminal: true)
        #expect(inFlight.isVisible(.openTerminal))
        #expect(!inFlight.isEnabled(.openTerminal))
        #expect(inFlight.blockReason(for: .openTerminal) == .actionInFlight)

        // not in flight + terminal wired => enabled
        let ready = policy(.installed, supportsDeploy: true, actionInFlight: false, canOpenTerminal: true)
        #expect(ready.isEnabled(.openTerminal))

        // no terminal wired => .notApplicable takes precedence over in-flight
        let noTerminal = policy(.installed, supportsDeploy: true, actionInFlight: true, canOpenTerminal: false)
        #expect(noTerminal.isVisible(.openTerminal) && !noTerminal.isEnabled(.openTerminal))
        #expect(noTerminal.blockReason(for: .openTerminal) == .notApplicable)
    }

    // MARK: - mayIssueInstall (action-side gate)

    @Test("mayIssueInstall is readiness/installability-gated but ignores in-flight")
    func mayIssueInstallSemantics() {
        #expect(policy(.notInstalled, actionInFlight: true).mayIssueInstall)
        #expect(policy(.installFailed(error: "e"), actionInFlight: true).mayIssueInstall)
        #expect(!policy(.installed).mayIssueInstall)
        #expect(!policy(.notInstalled, hostAllowsInstall: false).mayIssueInstall)
        #expect(!policy(.notInstalled, installability: .unavailable(reasonCode: .catalogOnly, message: nil)).mayIssueInstall)
    }

    // MARK: - Uninstall is independent of readiness/installability

    @Test("uninstall ignores readiness and installability, disabled only while in-flight")
    func uninstallIndependence() {
        let blockedHost = policy(.installed, installability: .unavailable(reasonCode: .catalogOnly, message: nil), hostAllowsInstall: false)
        #expect(blockedHost.isVisible(.uninstall) && blockedHost.isEnabled(.uninstall))

        let inFlight = policy(.installed, actionInFlight: true)
        #expect(inFlight.isVisible(.uninstall) && !inFlight.isEnabled(.uninstall))
        #expect(inFlight.blockReason(for: .uninstall) == .actionInFlight)
    }

    // MARK: - Facade equivalence (locks ClawDetailActionAvailability to the policy)

    @Test("ClawDetailActionAvailability facade projects the policy exactly")
    func facadeMatchesPolicy() {
        let states: [ClawInstallState] = [
            .notInstalled,
            .installing(nil),
            .uninstalling,
            .installed,
            .installedButBlocked(reasons: []),
            .installFailed(error: "e"),
            .unknown,
        ]
        let installabilities: [ClawInstallability] = [
            .installable,
            .unavailable(reasonCode: .catalogOnly, message: "m"),
        ]
        let bools = [true, false]

        for state in states {
            for inst in installabilities {
                for hostAllows in bools {
                    for supportsDeploy in bools {
                        let da = ClawDetailActionAvailability(
                            installState: state,
                            installability: inst,
                            allowsInstall: hostAllows,
                            supportsDeploy: supportsDeploy
                        )
                        // The facade hardcodes actionInFlight:false, canOpenTerminal:false.
                        let p = policy(
                            state,
                            installability: inst,
                            hostAllowsInstall: hostAllows,
                            supportsDeploy: supportsDeploy
                        )
                        #expect(da.showsInstall == p.isEnabled(.install))
                        #expect(da.showsRetryInstall == p.isEnabled(.retryInstall))
                        #expect(da.showsDeploy == p.isEnabled(.deploy))
                        #expect(da.showsUninstall == p.isVisible(.uninstall))
                        #expect(da.showsInstallingProgress == (p.transient == .installing))
                        #expect(da.showsUninstallingProgress == (p.transient == .uninstalling))
                        #expect(da.showsUnknownState == p.showsUnknownState)
                        #expect(da.showsDeployUnavailableNotice == (p.deployUnavailableReason != nil))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func policy(
        _ state: ClawInstallState,
        installability: ClawInstallability = .installable,
        hostAllowsInstall: Bool = true,
        supportsDeploy: Bool = true,
        actionInFlight: Bool = false,
        canOpenTerminal: Bool = false
    ) -> ClawActionPolicy {
        ClawActionPolicy(
            ClawActionPolicy.Input(
                installState: state,
                installability: installability,
                hostAllowsInstall: hostAllowsInstall,
                supportsDeploy: supportsDeploy,
                actionInFlight: actionInFlight,
                canOpenTerminal: canOpenTerminal
            )
        )
    }

    private func stateIsNotInstalled(_ s: ClawInstallState) -> Bool { if case .notInstalled = s { return true }; return false }
    private func stateIsInstallFailed(_ s: ClawInstallState) -> Bool { if case .installFailed = s { return true }; return false }
    private func stateIsInstalled(_ s: ClawInstallState) -> Bool { if case .installed = s { return true }; return false }
    private func stateIsInstalledButBlocked(_ s: ClawInstallState) -> Bool { if case .installedButBlocked = s { return true }; return false }
    private func stateIsInstalling(_ s: ClawInstallState) -> Bool { if case .installing = s { return true }; return false }
    private func stateIsUninstalling(_ s: ClawInstallState) -> Bool { if case .uninstalling = s { return true }; return false }
    private func stateIsUnknown(_ s: ClawInstallState) -> Bool { if case .unknown = s { return true }; return false }
}
