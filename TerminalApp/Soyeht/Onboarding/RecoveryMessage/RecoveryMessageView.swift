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
                        Text(LocalizedStringResource(
                            "recovery.title",
                            defaultValue: "Boa notícia.",
                            comment: "Recovery message title. Reassuring, positive. Period is intentional."
                        ))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "recovery.body",
                            defaultValue: "Se um dia você perder o iPhone, outro Mac pode recuperar sua casa. Suas chaves ficam seguras — não dependem de nenhum dispositivo sozinho.",
                            comment: "Recovery message body. Calm, non-alarming. Explains multi-device key recovery."
                        ))
                        .font(.system(size: 16))
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)

                    Button(action: onDismiss) {
                        Text(LocalizedStringResource(
                            "recovery.cta",
                            defaultValue: "Entendi",
                            comment: "Recovery message dismiss CTA."
                        ))
                        .font(.system(size: 17, weight: .semibold))
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
