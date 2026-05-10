import SwiftUI
import SoyehtCore

/// MA3 — Install progress scene.
/// Drives 4 sequential micro-steps with visual feedback per FR-013:
/// verificando → pedindo permissão → instalando → acordando.
///
/// T047 (EnginePackager), T048 (SMAppServiceInstaller), and T049
/// (HealthCheckPoller) each invoke `advance()` when their work completes.
/// Until those are wired, steps auto-advance with artificial delays.
struct InstallProgressView: View {
    /// Called when the engine is confirmed alive (FR-014 health check passes).
    let onReady: () -> Void

    @State private var completedSteps: Int = 0

    private let steps: [InstallStep] = [
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step1",
            defaultValue: "Verificando",
            comment: "MA3 step 1: checking prerequisites."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step2",
            defaultValue: "Pedindo permissão",
            comment: "MA3 step 2: registering LaunchAgent via SMAppService."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step3",
            defaultValue: "Instalando",
            comment: "MA3 step 3: copying engine binary to Application Support."
        )),
        InstallStep(label: LocalizedStringResource(
            "bootstrap.installProgress.step4",
            defaultValue: "Acordando",
            comment: "MA3 step 4: health-check polling until engine responds."
        )),
    ]

    var body: some View {
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

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await runInstallSequence() }
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

    /// Drives step progression. T047, T048, T049 will replace the artificial
    /// delays with real work completions when they are implemented.
    private func runInstallSequence() async {
        do {
            // Step 1: verificando — T048 prerequisite check
            try await Task.sleep(for: .milliseconds(800))
            await advance()

            // Step 2: pedindo permissão — T048 SMAppService.register()
            try await Task.sleep(for: .milliseconds(1_200))
            await advance()

            // Step 3: instalando — T047 EnginePackager.install()
            try await Task.sleep(for: .milliseconds(1_500))
            await advance()

            // Step 4: acordando — T049 HealthCheckPoller polls engine
            try await Task.sleep(for: .milliseconds(2_000))
            await advance()

            onReady()
        } catch {
            // Task cancelled (window closed); no-op.
        }
    }

    @MainActor private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) {
            completedSteps = min(completedSteps + 1, steps.count)
        }
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
        case .done:    return "concluído"
        }
    }
}
