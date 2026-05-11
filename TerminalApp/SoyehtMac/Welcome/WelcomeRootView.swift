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
        case setupAwaiting(ownerDisplayName: String?)  // iPhone setup-invitation discovered
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
        case .setupAwaiting(let ownerDisplayName):
            AwaitingNameFromiPhoneView(ownerDisplayName: ownerDisplayName, onNamed: onPaired)
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
        let scheme = SoyehtAPIClient.isLocalHost(TheyOSEnvironment.adminHost) ? "http" : "https"
        guard let baseURL = URL(string: "\(scheme)://\(TheyOSEnvironment.adminHost)") else { return }
        let client = BootstrapStatusClient(baseURL: baseURL)
        let status: BootstrapStatusResponse
        do {
            status = try await client.fetch()
        } catch {
            return  // engine offline / unresponsive → stay on .bootstrap
        }
        switch status.state {
        case .uninitialized, .readyForNaming:
            let listener = SetupInvitationListener(engineBaseURL: baseURL)
            let outcome = await listener.listen()
            switch outcome {
            case .invitationClaimed(let ownerDisplayName, _):
                mode = .setupAwaiting(ownerDisplayName: ownerDisplayName)
                await pollUntilNamed(client: client)
            default:
                break  // .notFound / .failed → stay on .bootstrap
            }
        case .namedAwaitingPair, .recovering:
            mode = .recover
        case .ready:
            onPaired()
        }
    }

    private func pollUntilNamed(client: BootstrapStatusClient) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let status = try? await client.fetch() else { continue }
            if status.state == .namedAwaitingPair || status.state == .ready {
                onPaired()
                return
            }
        }
    }
}
