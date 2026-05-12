import SwiftUI
import SoyehtCore

/// Top-level router for the Welcome window. Four mutually-exclusive modes
/// determined by engine state + Bonjour discovery at launch:
///
/// - `bootstrap`     — fresh Mac, no house yet (case A)
/// - `autoJoin`      — existing household found on Tailnet (US5)
/// - `setupAwaiting` — iPhone published a setup-invitation (case B, Mac side)
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
        case autoJoin       // existing household discovered on Tailnet
        case setupAwaiting(ownerDisplayName: String?)  // iPhone setup-invitation discovered
        case recover        // local engine state present
        case existingSoyeht(ExistingSoyehtContext)
    }

    /// Inner navigation steps for the bootstrap flow (case A, MA2+).
    /// MA1 is the NavigationStack root (BootstrapWelcomeView).
    enum BootstrapStep: Hashable {
        case installPreview        // MA2 — T042
        case installProgress       // MA3 — T043
        case houseNaming           // T044
        case houseCreation(String) // T045 — associated value: house name
        case houseCard(name: String, avatar: HouseAvatar, pairQrUri: String)
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
        case .existingSoyeht(let context):
            ExistingSoyehtView(
                onContinue: { await continueWithExistingSoyeht(context) },
                onReinstall: { await reinstallSoyeht(context) }
            )
        }
    }

    @ViewBuilder private func bootstrapStep(_ step: BootstrapStep) -> some View {
        switch step {
        case .installPreview:
            InstallPreviewView(onInstall: { bootstrapPath.append(.installProgress) })
        case .installProgress:
            InstallProgressView(onReady: {
                Task { await continueAfterInstallReady() }
            })
        case .houseNaming:
            HouseNamingView(onNamed: { name in
                bootstrapPath.append(.houseCreation(name))
            })
        case .houseCreation(let name):
            HouseCreationProgressView(houseName: name, onCreated: { response in
                let avatar = HouseAvatarDerivation.derive(hhPub: response.hhPub)
                bootstrapPath.append(.houseCard(name: name, avatar: avatar, pairQrUri: response.pairQrUri))
            })
        case .houseCard(let name, let avatar, let pairQrUri):
            HouseCardView(houseName: name, avatar: avatar, pairQrUri: pairQrUri, onPaired: onPaired)
        }
    }

    private func resolveMode() async {
        let baseURL = Self.bootstrapBaseURL()
        let client = BootstrapStatusClient(baseURL: baseURL)
        let status: BootstrapStatusResponse
        do {
            status = try await client.fetch()
        } catch {
            if await Self.isExistingSoyehtResponding() {
                mode = .existingSoyeht(ExistingSoyehtContext(status: nil))
            }
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
                mode = .existingSoyeht(ExistingSoyehtContext(status: status))
            }
        case .namedAwaitingPair, .recovering:
            mode = .existingSoyeht(ExistingSoyehtContext(status: status))
        case .ready:
            if SessionStore.shared.pairedServers.isEmpty {
                mode = .existingSoyeht(ExistingSoyehtContext(status: status))
            } else {
                onPaired()
            }
        }
    }

    private func continueWithExistingSoyeht(_ context: ExistingSoyehtContext) async -> LocalizedStringResource? {
        if let status = context.status {
            switch status.state {
            case .uninitialized, .readyForNaming:
                bootstrapPath = [.houseNaming]
                mode = .bootstrap
            case .namedAwaitingPair, .recovering:
                mode = .recover
            case .ready:
                if SessionStore.shared.pairedServers.isEmpty {
                    return await autoPairExistingSoyeht()
                }
                onPaired()
            }
            return nil
        }

        return await autoPairExistingSoyeht()
    }

    private func autoPairExistingSoyeht() async -> LocalizedStringResource? {
        do {
            _ = try await TheyOSAutoPairService().autoPair()
            onPaired()
            return nil
        } catch {
            return LocalizedStringResource(
                "welcome.existingSoyeht.continue.failed",
                defaultValue: "Couldn't continue with this Mac. You can reinstall Soyeht here.",
                comment: "Shown when an older local Soyeht is running, but the app cannot pair with it automatically."
            )
        }
    }

    private func reinstallSoyeht(_ context: ExistingSoyehtContext) async -> LocalizedStringResource? {
        guard await prepareForReinstall(context) else {
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

    private func continueAfterInstallReady() async {
        let baseURL = Self.bootstrapBaseURL()
        let listener = SetupInvitationListener(engineBaseURL: baseURL)
        let outcome = await listener.listen()
        switch outcome {
        case .invitationClaimed(let ownerDisplayName, _):
            mode = .setupAwaiting(ownerDisplayName: ownerDisplayName)
            bootstrapPath.removeAll()
            await pollUntilNamed(client: BootstrapStatusClient(baseURL: baseURL))
        case .notFound, .failed:
            bootstrapPath.append(.houseNaming)
        }
    }

    private func pollUntilNamed(client: BootstrapStatusClient) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let status = try? await client.fetch() else { continue }
            if status.state == .namedAwaitingPair || status.state == .ready {
                onPaired()
                return
            }
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
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(BrandColors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

private enum ExistingSoyehtStopper {
    static func stopKnownServices() async {
        let commands = serviceStopCommands()
        for command in commands {
            await runBestEffort(executable: command.executable, arguments: command.arguments)
        }
    }

    private static func serviceStopCommands() -> [(executable: String, arguments: [String])] {
        var commands: [(String, [String])] = [
            ("/bin/launchctl", ["bootout", "gui/\(getuid())/com.soyeht.engine"]),
        ]

        for brew in TheyOSEnvironment.brewBinaryCandidates where FileManager.default.isExecutableFile(atPath: brew) {
            commands.append((brew, ["services", "stop", "theyos"]))
        }

        for soyeht in ["/opt/homebrew/bin/soyeht", "/usr/local/bin/soyeht"]
            where FileManager.default.isExecutableFile(atPath: soyeht) {
            commands.append((soyeht, ["stop"]))
        }

        return commands
    }

    private static func runBestEffort(executable: String, arguments: [String]) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                runBestEffortBlocking(executable: executable, arguments: arguments)
                continuation.resume()
            }
        }
    }

    private static func runBestEffortBlocking(executable: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return
        }

        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }
    }
}

private enum ExistingSoyehtStateResetter {
    static func resetLocalEngineState() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                resetLocalEngineStateBlocking()
                continuation.resume()
            }
        }
    }

    private static func resetLocalEngineStateBlocking() {
        let fm = FileManager.default
        let supportDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Soyeht", isDirectory: true)

        let files = [
            "theyos.db", "theyos.db-shm", "theyos.db-wal",
            "theyos.sessions.db", "theyos.sessions.db-shm", "theyos.sessions.db-wal",
            "theyos.mobile-sessions.db", "theyos.mobile-sessions.db-shm", "theyos.mobile-sessions.db-wal",
            "jobs-rs.db", "jobs-rs.db-shm", "jobs-rs.db-wal",
            "ratelimit.db", "ratelimit.db-shm", "ratelimit.db-wal",
            "identity.bootstrap_state",
            "household.tearing-down",
        ]

        for file in files {
            try? fm.removeItem(at: supportDir.appendingPathComponent(file, isDirectory: false))
        }

        try? fm.removeItem(at: supportDir.appendingPathComponent("household", isDirectory: true))
    }
}
