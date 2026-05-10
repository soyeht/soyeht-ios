import SwiftUI
import SoyehtCore

/// Cena P10 — pairing complete celebration.
/// "Você é o primeiro morador da Casa [name]."
/// Transitions to `RecoveryMessageView` (US5) after celebration.
struct PairingSuccessView: View {
    let houseName: String
    let onContinue: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    Text("🎉")
                        .font(.system(size: 72))
                        .scaleEffect(appeared ? 1.0 : 0.5)
                        .opacity(appeared ? 1.0 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.65), value: appeared)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text(LocalizedStringResource(
                            "pairing.success.title",
                            defaultValue: "Você é o primeiro morador.",
                            comment: "Pairing success headline. Celebratory, first-person."
                        ))
                        .font(OnboardingFonts.heading)
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "pairing.success.subtitle",
                            defaultValue: "da \(houseName)",
                            comment: "Pairing success subtitle with house name."
                        ))
                        .font(OnboardingFonts.callout)
                        .foregroundColor(BrandColors.accentGreen)
                        .multilineTextAlignment(.center)
                    }

                    Button(action: onContinue) {
                        Text(LocalizedStringResource(
                            "pairing.success.cta",
                            defaultValue: "Continuar",
                            comment: "CTA: proceed from pairing success to recovery message."
                        ))
                        .font(OnboardingFonts.bodyBold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(BrandColors.accentGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.top, 8)
                }
                .padding(32)
                .frame(maxWidth: 360)

                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.1).delay(0.1)) {
                    appeared = true
                }
            }
        }
    }
}
