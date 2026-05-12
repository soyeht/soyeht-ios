import SwiftUI
import SoyehtCore

/// Carousel card 5 — Mac and iPhone, together (T085, US3).
struct CardMacAndIphone: View {
    var body: some View {
        CarouselCardLayout(
            illustration: splitIllustration,
            title: LocalizedStringResource(
                "carousel.card5.title",
                defaultValue: "Mac and iPhone, together",
                comment: "Carousel card 5 title: Mac and iPhone together."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card5.subtitle",
                defaultValue: "Set up on your Mac, then access it from anywhere on your iPhone. One home, two ways in.",
                comment: "Carousel card 5 subtitle: Mac is the base, iPhone is the portal."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card5.a11y",
            defaultValue: "Mac and iPhone, together. Set up on your Mac and access it from anywhere on your iPhone.",
            comment: "VoiceOver combined label for carousel card 5."
        )))
    }

    private var splitIllustration: some View {
        HStack(spacing: 16) {
            // Mac side
            deviceCard(
                icon: "laptopcomputer",
                label: "Mac",
                accent: BrandColors.accentGreen
            )

            // Connection line
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle()
                        .fill(BrandColors.accentGreen.opacity(0.5))
                        .frame(width: 4, height: 4)
                        .padding(.vertical, 3)
                }
            }
            .accessibilityHidden(true)

            // iPhone side
            deviceCard(
                icon: "iphone",
                label: "iPhone",
                accent: BrandColors.accentGreen
            )
        }
    }

    private func deviceCard(icon: String, label: String, accent: Color) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(accent)
            }
            Text(verbatim: label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandColors.textMuted)
        }
    }
}
