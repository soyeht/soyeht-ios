import SwiftUI
import SoyehtCore

/// iPhone-side 3-step pairing animation during pareamento commit.
/// Step 1: HapticDirector.pairingProgress (FR-110 step 1).
/// Step 3: HapticDirector.pairingSuccess (FR-110 step 2) + SoundDirector.casaCriada (FR-116).
struct PairingProgressView: View {
    let onComplete: () -> Void

    @State private var completedSteps: Int = 0

    private let steps: [(label: LocalizedStringResource, icon: String)] = [
        (
            LocalizedStringResource(
                "pairing.progress.step1",
                defaultValue: "Verificando",
                comment: "Pairing step 1: verifying safety codes."
            ),
            "checkmark.shield"
        ),
        (
            LocalizedStringResource(
                "pairing.progress.step2",
                defaultValue: "Entrando",
                comment: "Pairing step 2: joining the house."
            ),
            "person.badge.plus"
        ),
        (
            LocalizedStringResource(
                "pairing.progress.step3",
                defaultValue: "Pronto",
                comment: "Pairing step 3: pairing complete."
            ),
            "checkmark.circle.fill"
        ),
    ]

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringResource(
                        "pairing.progress.title",
                        defaultValue: "Entrando na casa…",
                        comment: "Pairing progress screen title."
                    ))
                    .font(OnboardingFonts.heading)
                    .foregroundColor(BrandColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                    ForEach(steps.indices, id: \.self) { idx in
                        stepRow(label: steps[idx].label, icon: steps[idx].icon, index: idx)
                    }
                }
                .padding(28)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .task { await runPairingSequence() }
    }

    @ViewBuilder
    private func stepRow(label: LocalizedStringResource, icon: String, index: Int) -> some View {
        let state = stepState(index: index)
        HStack(spacing: 14) {
            stepIcon(state: state, finalIcon: icon)
                .frame(width: 24, height: 24)
            Text(label)
                .font(OnboardingFonts.callout)
                .foregroundColor(labelColor(state: state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateLabel(state: state)))
    }

    @ViewBuilder
    private func stepIcon(state: StepState, finalIcon: String) -> some View {
        switch state {
        case .pending:
            Circle()
                .strokeBorder(BrandColors.border, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .active:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.65)
                .accessibilityHidden(true)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(BrandColors.accentGreen)
                .font(.system(size: 20))
                .accessibilityHidden(true)
        }
    }

    private func labelColor(state: StepState) -> Color {
        switch state {
        case .pending: return BrandColors.textMuted
        case .active:  return BrandColors.textPrimary
        case .done:    return BrandColors.accentGreen
        }
    }

    private func stateLabel(state: StepState) -> LocalizedStringKey {
        switch state {
        case .pending: return "pendente"
        case .active:  return "em andamento"
        case .done:    return "concluído"
        }
    }

    private func stepState(index: Int) -> StepState {
        if index < completedSteps { return .done }
        if index == completedSteps { return .active }
        return .pending
    }

    @MainActor
    private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) {
            completedSteps = min(completedSteps + 1, steps.count)
        }
    }

    private func runPairingSequence() async {
        do {
            // Step 1: verificando
            HapticDirector.live().fire(.pairingProgress)
            try await Task.sleep(for: .milliseconds(900))
            await advance()

            // Step 2: entrando
            try await Task.sleep(for: .milliseconds(1_200))
            await advance()

            // Step 3: pronto — pairing complete
            try await Task.sleep(for: .milliseconds(600))
            await advance()
            HapticDirector.live().fire(.pairingSuccess)
            SoundDirector.shared.play(.casaCriada)

            try await Task.sleep(for: .milliseconds(800))
            onComplete()
        } catch {
            // Task cancelled (view dismissed); no-op.
        }
    }

    private enum StepState { case pending, active, done }
}
