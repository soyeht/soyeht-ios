import SwiftUI
import SoyehtCore

/// Shared layout template for all 5 carousel cards.
/// illustration sits in the upper portion, title + subtitle at the bottom.
struct CarouselCardLayout<Illustration: View>: View {
    let illustration: Illustration
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    init(
        illustration: Illustration,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource
    ) {
        self.illustration = illustration
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            illustration
                .accessibilityHidden(true)

            Spacer()

            VStack(spacing: 12) {
                Text(title)
                    .font(OnboardingFonts.heading)
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(OnboardingFonts.callout)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
