import SwiftUI
import SoyehtCore

/// Sheet shown when pre-flight detects a cellular-only connection (FR-123).
/// Default highlighted action is "Esperar Wi-Fi" (conservative path, FR-119).
struct CellularConfirmationSheet: View {
    let onProceed: () -> Void
    let onWaitForWifi: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(BrandColors.accentAmber)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(LocalizedStringResource(
                    "cellular.sheet.title",
                    defaultValue: "Você está no dados móveis",
                    comment: "Cellular confirmation sheet title."
                ))
                .font(Font.title3.weight(.semibold))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "cellular.sheet.body",
                    defaultValue: "O instalador do Soyeht tem alguns megabytes. Recomendamos esperar uma conexão Wi-Fi pra não usar sua franquia.",
                    comment: "Cellular confirmation sheet body. Friendly tone about data usage."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Conservative action highlighted (FR-119)
                Button(action: onWaitForWifi) {
                    Text(LocalizedStringResource(
                        "cellular.sheet.waitWifi",
                        defaultValue: "Esperar Wi-Fi",
                        comment: "Conservative CTA: wait for Wi-Fi before downloading."
                    ))
                    .font(OnboardingFonts.bodyBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onProceed) {
                    Text(LocalizedStringResource(
                        "cellular.sheet.proceed",
                        defaultValue: "Continuar assim mesmo",
                        comment: "Secondary CTA: proceed despite cellular connection."
                    ))
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(BrandColors.textMuted)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(28)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }
}

/// Sheet shown when pre-flight detects low battery (FR-124).
/// Default highlighted action is "Carregar primeiro" (conservative path, FR-119).
struct LowBatteryWarningSheet: View {
    let onProceed: () -> Void
    let onChargeFirst: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "battery.25percent")
                .font(.system(size: 40))
                .foregroundColor(BrandColors.accentAmber)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(LocalizedStringResource(
                    "lowBattery.sheet.title",
                    defaultValue: "Bateria baixa",
                    comment: "Low battery warning sheet title."
                ))
                .font(Font.title3.weight(.semibold))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "lowBattery.sheet.body",
                    defaultValue: "Sua bateria está abaixo de 20%. O processo leva alguns minutos — melhor carregar um pouco antes de começar.",
                    comment: "Low battery warning body. Warm tone, non-alarming."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Conservative action highlighted (FR-119)
                Button(action: onChargeFirst) {
                    Text(LocalizedStringResource(
                        "lowBattery.sheet.chargeFirst",
                        defaultValue: "Carregar primeiro",
                        comment: "Conservative CTA: charge device before proceeding."
                    ))
                    .font(OnboardingFonts.bodyBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onProceed) {
                    Text(LocalizedStringResource(
                        "lowBattery.sheet.proceed",
                        defaultValue: "Tudo bem, continuar",
                        comment: "Secondary CTA: proceed despite low battery."
                    ))
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(BrandColors.textMuted)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(28)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }
}
