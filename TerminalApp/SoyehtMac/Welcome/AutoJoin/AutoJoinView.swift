import SwiftUI
import SoyehtCore

/// Phase 3 auto-join surface for a Mac that finds an existing casa on Tailnet.
/// The discovery runtime is owned by the pair-machine flow; this view provides
/// the polished waiting state instead of exposing transport details.
struct AutoJoinView: View {
    let onJoined: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(BrandColors.accentGreen.opacity(0.12))
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulse ? 1.08 : 0.96)
                    Image(systemName: "house.and.flag.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(BrandColors.accentGreen)
                }
                .accessibilityHidden(true)

                Text(LocalizedStringResource(
                    "bootstrap.autoJoin.title",
                    defaultValue: "Procurando sua casa",
                    comment: "Auto-join title while this Mac searches for an existing casa."
                ))
                .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                .foregroundColor(BrandColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "bootstrap.autoJoin.body",
                    defaultValue: "Mantenha o Soyeht aberto no iPhone para confirmar este Mac.",
                    comment: "Auto-join body directing the user to keep Soyeht open on iPhone."
                ))
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onJoined) {
                Text(LocalizedStringResource(
                    "bootstrap.autoJoin.manualContinue",
                    defaultValue: "Já confirmei",
                    comment: "Manual continue button for auto-join after confirming on iPhone."
                ))
                .font(MacTypography.Fonts.Controls.cta)
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
                .background(BrandColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.autoJoin.step",
            defaultValue: "Conectando",
            comment: "Step indicator for auto-join waiting state."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
    }
}
