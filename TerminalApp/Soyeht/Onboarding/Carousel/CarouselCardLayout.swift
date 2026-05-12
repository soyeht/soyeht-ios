import SwiftUI
import SoyehtCore

/// Shared layout template for all 5 carousel cards.
/// illustration sits in the upper portion, title + subtitle at the bottom.
struct CarouselCardLayout<Illustration: View>: View {
    let illustration: Illustration
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    @Environment(\.sizeCategory) private var sizeCategory

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
        if sizeCategory.isAccessibilityCategory {
            ScrollView {
                copyBlock
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            regularBody
        }
    }

    private var regularBody: some View {
        VStack(spacing: 0) {
            Spacer()

            illustration
                .accessibilityHidden(true)

            Spacer()

            copyBlock
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var copyBlock: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(
                    sizeCategory.isAccessibilityCategory
                        ? OnboardingFonts.callout.weight(.semibold)
                        : OnboardingFonts.heading
                )
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(
                    sizeCategory.isAccessibilityCategory
                        ? OnboardingFonts.subheadline
                        : OnboardingFonts.callout
                )
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
