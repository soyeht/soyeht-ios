import SwiftUI
import Observation
import SoyehtCore

@Observable
@MainActor
final class WelcomeOnboardingState {
    enum Phase: Equatable {
        case idle
        case listening
        case pairing
        case approving
        case done
        case error(String)
    }

    private(set) var phase: Phase = .listening

    var isListening: Bool {
        phase == .listening
    }

    func beginListening() {
        phase = .listening
    }

    func beginPairing() {
        phase = .pairing
    }

    func beginApproval() {
        phase = .approving
    }

    func finish() {
        phase = .done
    }

    func fail(_ reason: String) {
        phase = .error(reason)
    }
}

/// Top-level router for the Welcome window. Four mutually-exclusive modes
/// determined by engine state + Bonjour discovery at launch:
///
/// - `bootstrap`     — fresh Mac, no house yet (case A)
/// - `autoJoin`      — existing household found on Tailnet (US5)
/// - `recover`       — engine has local state, re-connect/resume
///
/// T049 wires `BootstrapStatusClient` into `resolveMode()`.
/// T070 wires `SetupInvitationBrowser` into `resolveMode()`.
/// Default (no engine / uninitialized): `.bootstrap`.
struct WelcomeRootView: View {
    struct ExistingSoyehtContext {
        let status: BootstrapStatusResponse?
    }

    enum Mode {
        case bootstrap      // Case A: founder fresh install
        case recover        // local engine state present
        case existingSoyeht(ExistingSoyehtContext)
    }

    /// Inner navigation steps for the bootstrap flow (case A, MA2+).
    /// MA1 is the NavigationStack root (BootstrapWelcomeView).
    enum BootstrapStep: Hashable {
        case installProgress       // MA3 — T043
        case connectAgents         // MCP onboarding (wires Claude Code / Codex / OpenCode / Droid)
        case houseNaming           // T044
        case houseCreation(String) // T045 — associated value: house name
        case houseCard(name: String, pairQrUri: String)
        case ready                 // M6 — setup finished
    }

    let onPaired: () -> Void

    @State private var mode: Mode = .bootstrap
    @State private var bootstrapPath: [BootstrapStep] = []
    @State private var onboardingState = WelcomeOnboardingState()

    var body: some View {
        modeContent
            .frame(width: 720, height: 540)
            .background(NeoPalette.cloud.canvas)
            .environment(\.neoPalette, .cloud)
            .preferredColorScheme(.light)
            .task { await resolveMode() }
    }

    @ViewBuilder private var modeContent: some View {
        switch mode {
        case .bootstrap:
            NavigationStack(path: $bootstrapPath) {
                BootstrapWelcomeView(
                    onContinue: {
                        // Stay in the listening phase here so the
                        // SetupInvitationListener continues scanning
                        // while the engine installs and a Caso B iPhone
                        // publication (FR-040) that arrives during
                        // installation is still claimed. The same
                        // invariant now also covers
                        // Continue-with-this-Mac → HouseNaming (Bug 2 fix
                        // 2026-05-21): any in-progress bootstrap
                        // navigation keeps the listener alive so a
                        // parallel iPhone setup invitation is still
                        // claimed. The listener is killed for real only
                        // at the actual commit moment to a founder-only
                        // path — `HouseNamingView.onNamed` below.
                        bootstrapPath.append(.installProgress)
                    }
                )
                .navigationDestination(for: BootstrapStep.self) { step in
                    bootstrapStep(step)
                }
            }
        case .recover:
            RecoverView(onRecovered: onPaired)
        case .existingSoyeht(let context):
            ExistingSoyehtView(
                onContinue: { await continueWithExistingSoyeht(context) },
                onReinstall: { await reinstallSoyeht(context) }
            )
        }
    }

    @ViewBuilder private func bootstrapStep(_ step: BootstrapStep) -> some View {
        switch step {
        case .installProgress:
            InstallProgressView(onReady: {
                Task { await continueAfterInstallReady() }
            })
        case .connectAgents:
            ConnectAgentsView(onContinue: {
                Task { await continueAfterAgentsStep() }
            })
        case .houseNaming:
            HouseNamingView(onNamed: { name in
                // Solo-founder commit: the user submitted a household name.
                // Stop the listener loop now. From this point on the founder
                // path is irrevocable until HouseCreation completes, and a
                // late iPhone setup-invitation must not yank us out of create.
                onboardingState.beginApproval()
                bootstrapPath.append(.houseCreation(name))
            })
        case .houseCreation(let name):
            HouseCreationProgressView(houseName: name, onCreated: { response in
                bootstrapPath.append(.houseCard(name: name, pairQrUri: response.pairQrUri))
            })
        case .houseCard(let name, let pairQrUri):
            HouseCardView(
                houseName: name,
                initialPairQrUri: pairQrUri,
                onContinueOnMac: { await ensureLocalCredential() },
                onPaired: { bootstrapPath.append(.ready) }
            )
        case .ready:
            MacReadyView(
                onConnectAgents: { bootstrapPath.append(.connectAgents) },
                onOpen: {
                    onboardingState.finish()
                    onPaired()
                }
            )
        }
    }

    /// Pre-paired state resolver.
    ///
    /// Runs as a long-lived loop so two cold-start races don't strand the
    /// user:
    ///
    ///   1. **Engine race** — the GUI can launch before the LaunchAgent
    ///      brings the engine up. A one-shot status fetch in that window
    ///      fails and leaves the user on the initial `.bootstrap` card with
    ///      no recovery.
    ///   2. **Listener race** — if the Mac.app is open before the user reaches
    ///      `AwaitingMacView` on iPhone, a single listener pass can miss the
    ///      invitation entirely.
    ///
    /// The loop retries engine status until reachable, then re-runs the
    /// listener while `onboardingState.isListening` is true. The first manual
    /// action that commits to a non-Caso-B path (reinstall, get-started, or
    /// submitting a solo household name in HouseNamingView) moves the state
    /// machine out of `.listening`. Continue-with-this-Mac for an uninitialized
    /// engine deliberately leaves the listener running so a parallel iPhone
    /// setup-invitation publication (FR-040) still arrives.
    private func resolveMode() async {
        let baseURL = Self.bootstrapBaseURL()
        let client = BootstrapStatusClient(baseURL: baseURL)

        while onboardingState.isListening && !Task.isCancelled {
            let status: BootstrapStatusResponse
            do {
                status = try await client.fetch()
            } catch {
                if onboardingState.isListening, case .existingSoyeht = mode {
                    // already surfaced; keep waiting silently
                } else if await Self.isExistingSoyehtResponding() {
                    guard onboardingState.isListening else { return }
                    mode = .existingSoyeht(ExistingSoyehtContext(status: nil))
                }
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            switch status.state {
            case .uninitialized, .readyForNaming:
                // The Mac names its own home. It used to run a
                // setup-invitation listener here and, on a claim, hand the
                // naming over to the phone — which meant two devices could
                // both think they owned the next step, and the engine was
                // asked to initialize with a claim token nothing modelled.
                guard onboardingState.isListening else { return }
                do {
                    if case .bootstrap = mode, !bootstrapPath.isEmpty {
                        // Someone is already partway through setup on this
                        // Mac. Swapping `mode` here would yank them out of
                        // the screen they are on every couple of seconds.
                    } else if case .existingSoyeht = mode {
                        // already shown; keep polling quietly
                    } else {
                        // One screen, not a fork. "Join an existing Soyeht"
                        // used to be offered here, on a decision a Mac meets
                        // exactly once and never again — so a second Mac
                        // bought later had no way in at all. It lives in
                        // Preferences › Devices now, where it can be reached
                        // for as long as the Mac does.
                        mode = .existingSoyeht(ExistingSoyehtContext(status: status))
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            case .namedAwaitingPair:
                if !(await showExistingHouseCardIfPossible()) {
                    mode = .existingSoyeht(ExistingSoyehtContext(status: status))
                }
                return
            case .recovering:
                mode = .existingSoyeht(ExistingSoyehtContext(status: status))
                return
            case .ready:
                if SessionStore.shared.credentialedCanonicalServers().isEmpty {
                    mode = .existingSoyeht(ExistingSoyehtContext(status: status))
                } else {
                    onboardingState.finish()
                    onPaired()
                }
                return
            }
        }
    }

    private func continueWithExistingSoyeht(_ context: ExistingSoyehtContext) async -> LocalizedStringResource? {
        if let status = context.status {
            switch status.state {
            case .uninitialized, .readyForNaming:
                // Do not leave `.listening` here. The user is navigating to
                // HouseNamingView but has not committed to a solo household
                // yet. An iPhone publishing a setup-invitation at this exact
                // moment must still be claimed.
                bootstrapPath = [.houseNaming]
                mode = .bootstrap
            case .namedAwaitingPair:
                onboardingState.beginPairing()
                if !(await showExistingHouseCardIfPossible()) {
                    mode = .recover
                }
            case .recovering:
                onboardingState.beginPairing()
                mode = .recover
            case .ready:
                onboardingState.beginPairing()
                if SessionStore.shared.credentialedCanonicalServers().isEmpty {
                    return await autoPairExistingSoyeht()
                }
                onboardingState.finish()
                onPaired()
            }
            return nil
        }

        onboardingState.beginPairing()
        return await autoPairExistingSoyeht()
    }

    private func autoPairExistingSoyeht() async -> LocalizedStringResource? {
        if let failure = await ensureLocalCredential() { return failure }
        onPaired()
        return nil
    }

    /// Mints this Mac's own engine credential without navigating anywhere, so
    /// both ways out of the house card (the button and the automatic advance
    /// once an iPhone pairs) can insist on it before the main window opens.
    private func ensureLocalCredential() async -> LocalizedStringResource? {
        // `TheyOSAutoPairService` only talks to the local engine
        // (`~/.theyos/bootstrap-token` + admin host on localhost). If the
        // user already paired a server through another flow — e.g.
        // `AddLinuxServerSheet` registers a remote Linux admin host and
        // then routes back through `continueOnMac` — there is nothing to
        // auto-pair; go straight home with the server they just added.
        if !SessionStore.shared.credentialedCanonicalServers().isEmpty {
            return nil
        }
        // Mint the credential HERE, before the main window exists. Going
        // through `LocalEngineContext.resolveDetailed()` also records the
        // verified server id, so the first pane does not run a second
        // self-pair and end up with two engine rows for one Mac. An engine
        // that is still booting is the normal case at first launch, so wait
        // for it instead of calling the Mac unusable.
        for attempt in 0..<5 {
            switch await LocalEngineContext.resolveDetailed() {
            case .resolved:
                return nil
            case .engineNotAnsweringYet:
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            case .unavailable:
                return Self.continueFailedMessage
            }
        }
        return Self.continueFailedMessage
    }

    private static let continueFailedMessage = LocalizedStringResource(
        "welcome.existingSoyeht.continue.failed",
        defaultValue: "Couldn't continue with this Mac. You can reinstall Soyeht here.",
        comment: "Shown when an older local Soyeht is running, but the app cannot pair with it automatically."
    )

    private func showExistingHouseCardIfPossible() async -> Bool {
        do {
            let response = try await BootstrapPairDeviceURIClient(baseURL: Self.bootstrapBaseURL()).fetch()
            bootstrapPath = [.houseCard(
                name: response.houseName,
                pairQrUri: response.pairDeviceURI
            )]
            mode = .bootstrap
            return true
        } catch {
            return false
        }
    }

    private func reinstallSoyeht(_ context: ExistingSoyehtContext) async -> LocalizedStringResource? {
        onboardingState.beginPairing()
        guard await prepareForReinstall(context) else {
            onboardingState.fail("reinstall_stop_failed")
            // Go back to watching. `fail` alone left the poller stopped for
            // good, so the screen sat on its error even after the engine
            // recovered on its own — and "Try again" was the only thing that
            // could ever change it.
            onboardingState.beginListening()
            Task { await resolveMode() }
            return LocalizedStringResource(
                "welcome.existingSoyeht.reinstall.stopFailed",
                defaultValue: "Couldn't close the current Soyeht. Try again.",
                comment: "Shown when reinstall cannot safely stop the currently running local Soyeht service."
            )
        }
        bootstrapPath = [.installProgress]
        mode = .bootstrap
        return nil
    }

    private func prepareForReinstall(_ context: ExistingSoyehtContext) async -> Bool {
        await teardownBootstrapStateIfAllowed(context)
        try? SMAppServiceInstaller.unregister()
        await ExistingSoyehtStopper.stopKnownServices()
        guard await waitForExistingSoyehtToStop() else { return false }
        await ExistingSoyehtStateResetter.resetLocalEngineState()
        return true
    }

    private func teardownBootstrapStateIfAllowed(_ context: ExistingSoyehtContext) async {
        guard let state = context.status?.state,
              state == .uninitialized || state == .readyForNaming else { return }
        try? await BootstrapTeardownClient(baseURL: Self.bootstrapBaseURL()).teardown(wipeKeychain: true)
    }

    private func waitForExistingSoyehtToStop() async -> Bool {
        for _ in 0..<10 {
            if !(await Self.isExistingSoyehtResponding()) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The Mac names its own home. It used to stand on a finished progress bar
    /// waiting for a setup invitation from an iPhone that, for most owners,
    /// was not running yet — a listener with a timeout, which the owner read
    /// as the app hanging on "Ready". Naming is one field and it belongs to
    /// whoever is sitting at the machine.
    private func continueAfterInstallReady() async {
        let baseURL = Self.bootstrapBaseURL()
        if await routeExistingEngineStateAfterInstall(baseURL: baseURL) {
            return
        }
        bootstrapPath.append(.houseNaming)
    }

    /// Transition from the connect-agents step to the next bootstrap step.
    /// Today that's house naming; if a setup invitation arrives during
    /// the agents step (rare race), we let the existing listener path
    /// handle it on the next pass.
    /// The agents step is optional and reached from M6, so finishing it goes
    /// back to M6 rather than onward.
    private func continueAfterAgentsStep() async {
        if bootstrapPath.last == .connectAgents {
            bootstrapPath.removeLast()
            return
        }
        if await routeExistingEngineStateAfterInstall(baseURL: Self.bootstrapBaseURL()) {
            return
        }
        bootstrapPath.append(.houseNaming)
    }

    private func routeExistingEngineStateAfterInstall(baseURL: URL) async -> Bool {
        guard let status = try? await BootstrapStatusClient(baseURL: baseURL).fetch() else {
            return false
        }

        switch status.state {
        case .uninitialized, .readyForNaming:
            return false
        case .namedAwaitingPair:
            bootstrapPath.removeAll()
            if await showExistingHouseCardIfPossible() {
                return true
            }
            mode = .existingSoyeht(ExistingSoyehtContext(status: status))
            return true
        case .recovering:
            bootstrapPath.removeAll()
            mode = .existingSoyeht(ExistingSoyehtContext(status: status))
            return true
        case .ready:
            bootstrapPath.removeAll()
            if SessionStore.shared.credentialedCanonicalServers().isEmpty {
                mode = .existingSoyeht(ExistingSoyehtContext(status: status))
            } else {
                onPaired()
            }
            return true
        }
    }

    private static func bootstrapBaseURL() -> URL {
        TheyOSEnvironment.bootstrapBaseURL
    }

    private static func isExistingSoyehtResponding() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            var request = URLRequest(url: TheyOSEnvironment.healthURL)
            request.timeoutInterval = 1
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return false
            }
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            return body.contains("soyeht") || body.contains("theyos")
        } catch {
            return false
        }
    }
}

private struct ExistingSoyehtView: View {
    let onContinue: () async -> LocalizedStringResource?
    let onReinstall: () async -> LocalizedStringResource?

    @State private var isWorking = false
    @State private var errorMessage: LocalizedStringResource?
    @State private var showReinstallConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(BrandColors.accentGreenStrong.opacity(0.18))
                        .frame(width: 78, height: 78)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(BrandColors.accentGreenStrong)
                }
                .accessibilityHidden(true)

                Text(LocalizedStringResource(
                    "welcome.existingSoyeht.title",
                    defaultValue: "I found Soyeht already running on this Mac.",
                    comment: "Welcome screen title shown when a local Soyeht service is already running."
                ))
                .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                .foregroundColor(BrandColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "welcome.existingSoyeht.body",
                    defaultValue: "You can keep using this Mac as it is, or reinstall Soyeht here.",
                    comment: "Welcome screen body explaining the two choices in plain language."
                ))
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 24)
            }

            Spacer()

            HStack(spacing: 12) {
                if isWorking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(BrandColors.accentGreenStrong)
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "welcome.existingSoyeht.working",
                            defaultValue: "Preparing",
                            comment: "Accessibility label while the existing-Soyeht action is running."
                        )))
                }

                Spacer()

                Button {
                    showReinstallConfirmation = true
                } label: {
                    Text(LocalizedStringResource(
                        "welcome.existingSoyeht.reinstall",
                        defaultValue: "Reinstall",
                        comment: "Secondary action to reinstall Soyeht on this Mac."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.textPrimary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(BrandColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: MacSurface.Radius.card)
                            .stroke(BrandColors.border, lineWidth: MacSurface.Border.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.card))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button {
                    run(onContinue)
                } label: {
                    Text(LocalizedStringResource(
                        "welcome.existingSoyeht.continue",
                        defaultValue: "Continue with this Mac",
                        comment: "Primary action to keep using the local Soyeht already running on this Mac."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.buttonTextOnAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 24)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.card))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            String(
                localized: "welcome.existingSoyeht.reinstall.confirm.title",
                defaultValue: "Reinstall Soyeht on this Mac?",
                comment: "Confirmation alert title before reinstalling Soyeht on this Mac."
            ),
            isPresented: $showReinstallConfirmation
        ) {
            Button(
                String(
                    localized: "welcome.existingSoyeht.reinstall.confirm.cancel",
                    defaultValue: "Cancel",
                    comment: "Cancel button in the reinstall confirmation alert."
                ),
                role: .cancel
            ) {}
            Button(
                String(
                    localized: "welcome.existingSoyeht.reinstall.confirm.action",
                    defaultValue: "Reinstall",
                    comment: "Destructive confirmation button to reinstall Soyeht on this Mac."
                ),
                role: .destructive
            ) {
                run(onReinstall)
            }
        } message: {
            Text(LocalizedStringResource(
                "welcome.existingSoyeht.reinstall.confirm.body",
                defaultValue: "This closes the current Soyeht and prepares the app again.",
                comment: "Confirmation alert body before reinstalling Soyeht on this Mac."
            ))
        }
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "welcome.existingSoyeht.badge",
            defaultValue: "Soyeht on this Mac",
            comment: "Badge shown on the screen that found an existing local Soyeht service."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.buttonTextOnAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.accentGreen)
        .clipShape(Capsule())
    }

    private func run(_ action: @escaping () async -> LocalizedStringResource?) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let message = await action()
            await MainActor.run {
                errorMessage = message
                isWorking = false
            }
        }
    }
}
