import SwiftUI
import SoyehtCore

/// M2 — the wait. One bar and one sentence, because four ticking micro-steps
/// only tell the owner how many ways this could fail.
///
/// Two things it must never do again: replace the whole screen with the
/// Login Items request (the progress vanished and the step looked lost), and
/// sit on a spinner after macOS granted the permission in another window
/// (nothing re-checked, so the only way forward was quitting).
struct InstallProgressView: View {
    /// Called when the engine is confirmed alive.
    let onReady: () -> Void

    @State private var completedSteps: Int = 0
    @State private var approvalRequired = false
    @State private var approvalStillWaiting = false
    @State private var errorMessage: LocalizedStringResource?
    @State private var installAttempt = UUID()

    private let palette = NeoPalette.cloud
    private static let phaseCount = 3

    var body: some View {
        WelcomeStepScaffold(
            step: 2,
            title: LocalizedStringResource(
                "bootstrap.installProgress.title",
                defaultValue: "Setting up…",
                comment: "M2: title while the engine is installed and started."
            ),
            content: {
                VStack(alignment: .leading, spacing: 24) {
                    NeoProgressBar(
                        progress: Double(completedSteps) / Double(Self.phaseCount),
                        label: nil,
                        palette: palette
                    )
                    .accessibilityIdentifier(WelcomeAccessibilityID.m2Progress)

                    Text(phaseLabel)
                        .font(NeoFont.body)
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityIdentifier(WelcomeAccessibilityID.m2Phase)

                    if approvalRequired {
                        LoginItemsApprovalCard(
                            stillWaiting: approvalStillWaiting,
                            onOpenSettings: openLoginItemsSettings,
                            onRecheck: { recheckApproval(auto: false) }
                        )
                    }

                    if let errorMessage {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(errorMessage)
                                .font(NeoFont.body)
                                .foregroundStyle(palette.danger)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: retryInstall) {
                                Text(LocalizedStringResource(
                                    "bootstrap.installProgress.retry",
                                    defaultValue: "Try again",
                                    comment: "M2: retry button after a failed install."
                                ))
                            }
                            .buttonStyle(NeoPillButtonStyle(.secondary, palette: palette, fillsWidth: false))
                            .accessibilityIdentifier(WelcomeAccessibilityID.m2Retry)
                        }
                    }
                }
            }
        )
        // The task lives on the scaffold, not inside a branch: when the
        // approval card appeared inside its own screen the install task was
        // torn out of the view tree with it, so granting the permission left
        // nothing running to notice.
        .task(id: installAttempt) { await runInstallSequence() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard approvalRequired else { return }
            recheckApproval(auto: true)
        }
    }

    private var phaseLabel: LocalizedStringResource {
        switch completedSteps {
        case 0, 1:
            return LocalizedStringResource(
                "bootstrap.installProgress.phase.installing",
                defaultValue: "Installing the engine",
                comment: "M2: first phase — copying the engine into place."
            )
        case 2:
            return LocalizedStringResource(
                "bootstrap.installProgress.phase.starting",
                defaultValue: "Starting it",
                comment: "M2: second phase — the engine is registered and booting."
            )
        default:
            return LocalizedStringResource(
                "bootstrap.installProgress.phase.ready",
                defaultValue: "Ready",
                comment: "M2: final phase — the engine answered."
            )
        }
    }

    /// Drives the install with the real installer work behind it.
    private func runInstallSequence() async {
        await MainActor.run {
            completedSteps = 0
            errorMessage = nil
        }

        do {
            try Task.checkCancellation()

            try await Task.detached(priority: .userInitiated) {
                try EnginePackager.install()
            }.value
            advance()

            try await Task.detached(priority: .userInitiated) {
                try SMAppServiceInstaller.register()
            }.value
            advance()

            _ = try await HealthCheckPoller(client: Self.boundedStatusClient()).pollUntilReady()
            advance()

            await MainActor.run { onReady() }
        } catch let error as SMAppServiceInstaller.InstallerError {
            handleInstallerError(error)
        } catch EnginePackagerError.supportBinaryNotFound {
            await MainActor.run {
                completedSteps = 0
                errorMessage = LocalizedStringResource(
                    "bootstrap.installProgress.missingEngine",
                    defaultValue: "This update did not include the local Soyeht engine. Download the app again and try again.",
                    comment: "Mac install progress failure when the app bundle is missing the local engine binary."
                )
            }
        } catch {
            guard !(error is CancellationError) else { return }
            await MainActor.run {
                completedSteps = 0
                errorMessage = LocalizedStringResource(
                    "bootstrap.installProgress.failed",
                    defaultValue: "Couldn't start Soyeht on this Mac. Try again.",
                    comment: "Mac install progress failure message. Avoids technical wording."
                )
            }
        }
    }

    /// A five-second request timeout, so a host that accepts the connection
    /// and then says nothing cannot hold the whole step for the poller's full
    /// error budget.
    private static func boundedStatusClient() -> BootstrapStatusClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        return BootstrapStatusClient(
            baseURL: TheyOSEnvironment.bootstrapBaseURL,
            transport: { try await session.data(for: $0) }
        )
    }

    @MainActor private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) {
            completedSteps = min(completedSteps + 1, Self.phaseCount)
        }
    }

    @MainActor private func handleInstallerError(_ error: SMAppServiceInstaller.InstallerError) {
        switch SMAppServiceFailureCoordinator.action(for: error) {
        case .showApprovalUI:
            approvalRequired = true
            approvalStillWaiting = false
        case .retryThenReinstall, .logAndRetry, .treatAsEnabled:
            completedSteps = 0
            errorMessage = LocalizedStringResource(
                "bootstrap.installProgress.enableFailed",
                defaultValue: "Couldn't enable Soyeht on this Mac. Try again.",
                comment: "Mac install progress failure while enabling the local Mac service. Avoids technical wording."
            )
        }
    }

    private func openLoginItemsSettings() {
        NSWorkspace.shared.open(LoginItemsApprovalCard.settingsURL)
    }

    /// Coming back from System Settings is the signal that something may have
    /// changed. Ask the installer, and if it says enabled just carry on — the
    /// owner should not have to press a button to confirm what they already
    /// did in another window.
    private func recheckApproval(auto: Bool) {
        Task { @MainActor in
            for attempt in 0..<(auto ? 10 : 1) {
                if case .enabled = SMAppServiceInstaller.status {
                    approvalRequired = false
                    approvalStillWaiting = false
                    retryInstall()
                    return
                }
                if attempt < 9 { try? await Task.sleep(for: .seconds(1)) }
            }
            approvalStillWaiting = true
        }
    }

    @MainActor private func retryInstall() {
        approvalRequired = false
        completedSteps = 0
        errorMessage = nil
        installAttempt = UUID()
    }
}
