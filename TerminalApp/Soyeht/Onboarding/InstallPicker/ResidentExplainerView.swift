import SwiftUI
import SoyehtCore

/// Inline expanding link explaining the "living here" concept per FR-023.
/// Tapping the link reveals a short prose block with the product metaphor.
struct ResidentExplainerView: View {
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
                        "residentExplainer.trigger",
                        defaultValue: "What does 'living here' mean?",
                        comment: "Expandable link trigger explaining the living-here concept."
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
                "residentExplainer.trigger.a11y",
                defaultValue: "Explanation: what does living in Soyeht mean?",
                comment: "VoiceOver label for the resident concept disclosure button."
            )))

            if expanded {
                Text(LocalizedStringResource(
                    "residentExplainer.body",
                    defaultValue: "Living here means your Mac is the physical base for your digital home. It stores your data and runs your agents, like a real home has a foundation. You can access it from any device, but the Mac is the center.",
                    comment: "Prose explaining what 'living here' means in Soyeht. Keep warm and non-technical."
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
