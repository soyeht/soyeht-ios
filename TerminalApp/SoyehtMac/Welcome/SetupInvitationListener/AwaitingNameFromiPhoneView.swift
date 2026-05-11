import SwiftUI
import SoyehtCore

/// Mac shows "Aguardando o iPhone..." (T071).
/// Displayed when mode == .setupAwaiting — setup-invitation was found and claimed;
/// iPhone is expected to POST /bootstrap/initialize with the house name shortly.
struct AwaitingNameFromiPhoneView: View {
    let ownerDisplayName: String?
    let onNamed: () -> Void

    @State private var dotCount = 1

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                phoneIllustration

                VStack(spacing: 12) {
                    (Text(LocalizedStringResource(
                        "awaitingName.title",
                        defaultValue: "Aguardando o iPhone",
                        comment: "Awaiting name from iPhone title. Animated dots appended separately."
                    )) + Text(verbatim: dots))
                    .font(MacTypography.Fonts.Display.heroTitle)
                    .foregroundColor(BrandColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "awaitingName.title",
                        defaultValue: "Aguardando o iPhone",
                        comment: "VoiceOver label for awaiting title — no animated dots."
                    )))

                    if let name = ownerDisplayName {
                        Text(LocalizedStringResource(
                            "awaitingName.owner",
                            defaultValue: "Preparado para \(name)",
                            comment: "Shows owner's name if available from the setup invitation."
                        ))
                        .font(MacTypography.Fonts.Display.heroSubtitle)
                        .foregroundColor(BrandColors.accentGreen)
                    }

                    Text(LocalizedStringResource(
                        "awaitingName.subtitle",
                        defaultValue: "O iPhone vai enviar o nome da casa em instantes.",
                        comment: "Awaiting name subtitle explaining the iPhone will send the name."
                    ))
                    .font(MacTypography.Fonts.Display.heroSubtitle)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 60)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                dotCount = (dotCount % 3) + 1
            }
        }
    }

    private var dots: String { String(repeating: ".", count: dotCount) }

    private var phoneIllustration: some View {
        ZStack {
            Circle()
                .fill(BrandColors.accentGreen.opacity(0.1))
                .frame(width: 100, height: 100)

            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 40))
                .foregroundColor(BrandColors.accentGreen)
        }
        .accessibilityHidden(true)
    }
}
