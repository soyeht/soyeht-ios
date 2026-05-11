import SwiftUI
import SoyehtCore

/// MA3 — Install progress scene.
/// Drives 4 sequential micro-steps with visual feedback per FR-013:
/// verificando → pedindo permissão → instalando → acordando.
///
/// T047 (EnginePackager), T048 (SMAppServiceInstaller), and T049
/// (HealthCheckPoller) each advance only when their real work completes.
struct InstallProgressView: View {
    /// Called when the engine is confirmed alive (FR-014 health check passes).
    let onReady: () -> Void

    @State private var completedSteps: Int = 0
    @State private var approvalRequired = false
    @State private var errorMessage: LocalizedStringResource?
    @State private var installAttempt = UUID()

    private let steps: [InstallStep] = [
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step1",
            defaultValue: "Verificando",
            comment: "MA3 step 1: checking prerequisites."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step2",
            defaultValue: "Instalando",
            comment: "MA3 step 2: copying engine binary to Application Support."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step3",
            defaultValue: "Habilitando",
            comment: "MA3 step 3: registering LaunchAgent via SMAppService."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step4",
            defaultValue: "Acordando",
            comment: "MA3 step 4: health-check polling until engine responds."
        )),
    ]

    var body: some View {
        if approvalRequired {
            RequiresLoginItemsApprovalView(onRetry: retryInstall)
        } else {
            progressBody
                .task(id: installAttempt) { await runInstallSequence() }
        }
    }

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            Text(LocalizedStringResource(
                "bootstrap.installProgress.title",
                defaultValue: "Configurando o Soyeht…",
                comment: "MA3: Title shown during install progress."
            ))
            .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
            .foregroundColor(BrandColors.textPrimary)
            .padding(.bottom, 32)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(steps.indices, id: \.self) { idx in
                    StepRow(
                        step: steps[idx],
                        state: stepState(index: idx)
                    )
                }
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Text(errorMessage)
                        .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                        .foregroundColor(BrandColors.accentAmber)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: retryInstall) {
                        Text(LocalizedStringResource(
                            "bootstrap.installProgress.retry",
                            defaultValue: "Tentar de novo",
                            comment: "Retry button for Mac install progress failures."
                        ))
                        .font(MacTypography.Fonts.Controls.cta)
                        .foregroundColor(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 22)
                        .background(BrandColors.accentGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 24)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.installProgress.step",
            defaultValue: "Passo 1 de 3",
            comment: "MA3: Step indicator (installation phase)."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
    }

    private func stepState(index: Int) -> StepRow.StepState {
        if index < completedSteps { return .done }
        if index == completedSteps { return .active }
        return .pending
    }

    /// Drives step progression with real installer work.
    private func runInstallSequence() async {
        await MainActor.run {
            completedSteps = 0
            errorMessage = nil
        }

        do {
            try Task.checkCancellation()
            advance()

            try await Task.detached(priority: .userInitiated) {
                try EnginePackager.install()
            }.value
            advance()

            try await Task.detached(priority: .userInitiated) {
                try SMAppServiceInstaller.register()
            }.value
            advance()

            _ = try await HealthCheckPoller(baseURL: Self.bootstrapBaseURL()).pollUntilReady()
            advance()

            await MainActor.run { onReady() }
        } catch let error as SMAppServiceInstaller.InstallerError {
            handleInstallerError(error)
        } catch {
            guard !(error is CancellationError) else { return }
            await MainActor.run {
                errorMessage = LocalizedStringResource(
                    "bootstrap.installProgress.failed",
                    defaultValue: "O Soyeht não conseguiu ficar vivo neste Mac. Verifique o instalador e tente de novo.",
                    comment: "Mac install progress failure message. Avoids technical wording."
                )
            }
        }
    }

    @MainActor private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) {
            completedSteps = min(completedSteps + 1, steps.count)
        }
    }

    @MainActor private func handleInstallerError(_ error: SMAppServiceInstaller.InstallerError) {
        switch SMAppServiceFailureCoordinator.action(for: error) {
        case .showApprovalUI:
            approvalRequired = true
        case .retryThenReinstall, .logAndRetry, .treatAsEnabled:
            errorMessage = LocalizedStringResource(
                "bootstrap.installProgress.failed",
                defaultValue: "O Soyeht não conseguiu ficar vivo neste Mac. Verifique o instalador e tente de novo.",
                comment: "Mac install progress failure message. Avoids technical wording."
            )
        }
    }

    @MainActor private func retryInstall() {
        approvalRequired = false
        completedSteps = 0
        errorMessage = nil
        installAttempt = UUID()
    }

    private static func bootstrapBaseURL() -> URL {
        let scheme = SoyehtAPIClient.isLocalHost(TheyOSEnvironment.adminHost) ? "http" : "https"
        return URL(string: "\(scheme)://\(TheyOSEnvironment.adminHost)")!
    }
}

private struct InstallStep {
    let label: LocalizedStringResource
}

private struct StepRow: View {
    enum StepState { case pending, active, done }

    let step: InstallStep
    let state: StepState

    var body: some View {
        HStack(spacing: 14) {
            stepIcon
                .frame(width: 20)
            Text(step.label)
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(labelColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateLabel))
    }

    @ViewBuilder private var stepIcon: some View {
        switch state {
        case .pending:
            Circle()
                .strokeBorder(BrandColors.border, lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        case .active:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(BrandColors.accentGreen)
                .font(.system(size: 16))
                .accessibilityHidden(true)
        }
    }

    private var labelColor: Color {
        switch state {
        case .pending: return BrandColors.textMuted
        case .active:  return BrandColors.textPrimary
        case .done:    return BrandColors.accentGreen
        }
    }

    private var stateLabel: LocalizedStringKey {
        switch state {
        case .pending: return "pendente"
        case .active:  return "em andamento"
        case .done:    return "pronto"
        }
    }
}
