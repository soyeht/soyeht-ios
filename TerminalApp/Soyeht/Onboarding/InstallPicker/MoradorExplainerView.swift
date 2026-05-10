import SwiftUI
import SoyehtCore

/// Inline expanding link "Como assim, 'morar'?" per FR-023.
/// Tapping the link reveals a short prose block explaining the "morar" concept.
struct MoradorExplainerView: View {
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(BrandColors.accentGreen)
                        .accessibilityHidden(true)

                    Text(LocalizedStringResource(
                        "moradorExplainer.trigger",
                        defaultValue: "Como assim, 'morar'?",
                        comment: "Expandable link trigger explaining the morar concept."
                    ))
                    .font(OnboardingFonts.footnote)
                    .foregroundColor(BrandColors.accentGreen)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BrandColors.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringResource(
                "moradorExplainer.trigger.a11y",
                defaultValue: "Explicação: o que significa morar no Soyeht?",
                comment: "VoiceOver label for the morador concept disclosure button."
            )))

            if expanded {
                Text(LocalizedStringResource(
                    "moradorExplainer.body",
                    defaultValue: "Morar significa que seu Mac é a base física da sua casa digital. Ele armazena os dados e roda os agentes — como uma casa de verdade tem alicerces. Você acessa de qualquer dispositivo, mas o Mac é o centro.",
                    comment: "Prose explaining what 'morar' means in Soyeht. Keep warm and non-technical."
                ))
                .font(OnboardingFonts.footnote)
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.leading, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
