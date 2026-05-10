import SwiftUI
import SoyehtCore

/// Top-level router for the Welcome window. Four mutually-exclusive modes
/// determined by engine state + Bonjour discovery at launch:
///
/// - `bootstrap`     — fresh Mac, no house yet (Caso A)
/// - `autoJoin`      — existing casa found on Tailnet (US5)
/// - `setupAwaiting` — iPhone published a setup-invitation (Caso B, Mac side)
/// - `recover`       — engine has local state, re-connect/resume
///
/// T049 wires `BootstrapStatusClient` into `resolveMode()`.
/// T070 wires `SetupInvitationBrowser` into `resolveMode()`.
/// Default (no engine / uninitialized): `.bootstrap`.
struct WelcomeRootView: View {
    enum Mode {
        case bootstrap      // Caso A: founder fresh install
        case autoJoin       // existing casa discovered on Tailnet
        case setupAwaiting  // iPhone setup-invitation discovered
        case recover        // local engine state present
    }

    /// Inner navigation steps for the bootstrap flow (Caso A, MA2+).
    /// MA1 is the NavigationStack root (BootstrapWelcomeView).
    enum BootstrapStep: Hashable {
        case installPreview        // MA2 — T042
        case installProgress       // MA3 — T043
        case houseNaming           // T044
        case houseCreation(String) // T045 — associated value: house name
        case houseCard(String)     // T046 — associated value: house name
    }

    let onPaired: () -> Void

    @State private var mode: Mode = .bootstrap
    @State private var bootstrapPath: [BootstrapStep] = []

    var body: some View {
        modeContent
            .frame(width: 640, height: 540)
            .background(BrandColors.surfaceDeep)
            .preferredColorScheme(BrandColors.preferredColorScheme)
            .task { await resolveMode() }
    }

    @ViewBuilder private var modeContent: some View {
        switch mode {
        case .bootstrap:
            NavigationStack(path: $bootstrapPath) {
                BootstrapWelcomeView(
                    onContinue: { bootstrapPath.append(.installPreview) }
                )
                .navigationDestination(for: BootstrapStep.self) { step in
                    bootstrapStep(step)
                }
            }
        case .autoJoin:
            AutoJoinView(onJoined: onPaired)
        case .setupAwaiting:
            // T071: AwaitingNameFromiPhoneView
            Text(verbatim: "TODO: AwaitingNameFromiPhoneView (T071)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundColor(BrandColors.textMuted)
        case .recover:
            RecoverView(onRecovered: onPaired)
        }
    }

    @ViewBuilder private func bootstrapStep(_ step: BootstrapStep) -> some View {
        switch step {
        case .installPreview:
            InstallPreviewView(onInstall: { bootstrapPath.append(.installProgress) })
        case .installProgress:
            InstallProgressView(onReady: { bootstrapPath.append(.houseNaming) })
        case .houseNaming:
            HouseNamingView(onNamed: { name in
                bootstrapPath.append(.houseCreation(name))
            })
        case .houseCreation(let name):
            HouseCreationProgressView(houseName: name, onCreated: { bootstrapPath.append(.houseCard(name)) })
        case .houseCard(let name):
            HouseCardView(houseName: name, avatar: nil, onPaired: onPaired)
        }
    }

    private func resolveMode() async {
        // T049: probe BootstrapStatusClient — if state ≠ .uninitialized, switch to .recover
        // T070: run SetupInvitationBrowser — if invitation found, switch to .setupAwaiting
        // US5 (autoJoin): browse _soyeht-household._tcp. — if casa found, switch to .autoJoin
        // Default: .bootstrap (fresh Mac, engine not running or uninitialized)
    }
}
