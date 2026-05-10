import SwiftUI
import SoyehtCore

/// "Boa notícia" post-pairing recovery info screen (T110, FR-050).
/// Shown after first morador confirmation. Informational only — not actionable.
/// Surfaces `KeyHandoffMetaphorView` animation; "Entendi" CTA dismisses.
struct RecoveryMessageView: View {
    let onDismiss: () -> Void

    @State private var ctaEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    KeyHandoffMetaphorView(
                        onComplete: {
                            withAnimation(.easeIn(duration: 0.2)) {
                                ctaEnabled = true
                            }
                        }
                    )

                    VStack(spacing: 14) {
                        Text("recovery.title", comment: "Recovery message title. Reassuring, positive. Period is intentional.")
                        .font(OnboardingFonts.headingLarge)
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text("recovery.body", comment: "Recovery message body. Calm, non-alarming. Explains multi-device key recovery.")
                        .font(OnboardingFonts.callout)
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)

                    Button(action: onDismiss) {
                        Text("recovery.cta", comment: "Recovery message dismiss CTA.")
                        .font(OnboardingFonts.bodyBold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(ctaEnabled ? BrandColors.accentGreen : BrandColors.border)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!ctaEnabled)
                    .padding(.horizontal, 32)
                    .animation(.easeIn(duration: 0.2), value: ctaEnabled)
                }

                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear {
            // Reduce Motion: skip animation, enable CTA immediately.
            if reduceMotion {
                ctaEnabled = true
            }
        }
    }
}
