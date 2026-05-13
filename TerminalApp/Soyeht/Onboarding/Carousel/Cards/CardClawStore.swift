import SwiftUI
import SoyehtCore

/// Carousel card 1 — Claw Store (T081, US3).
struct CardClawStore: View {
    var body: some View {
        CarouselCardLayout(
            illustration: clawIllustration,
            title: LocalizedStringResource(
                "carousel.card1.title",
                defaultValue: "A whole team of agents, safely isolated",
                comment: "Carousel card 1 title: Claw Store."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card1.subtitle",
                defaultValue: "One agent is never enough. Visit the Claw Store and spin up agents with a single tap.",
                comment: "Carousel card 1 subtitle: describes Claw Store."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card1.a11y",
            defaultValue: "A whole team of agents, safely isolated. One agent is never enough. Visit the Claw Store and spin up agents with a single tap.",
            comment: "VoiceOver combined label for carousel card 1."
        )))
    }

    private var clawIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(BrandColors.accentGreen.opacity(0.15))
                .frame(width: 180, height: 180)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    appIcon(color: SoyehtTheme.accentGreen, icon: "cpu")
                    appIcon(color: SoyehtTheme.accentInfo.opacity(0.7), icon: "mic")
                    appIcon(color: SoyehtTheme.accentAlternate.opacity(0.7), icon: "network")
                }
                HStack(spacing: 8) {
                    appIcon(color: SoyehtTheme.accentAmber.opacity(0.7), icon: "calendar")
                    appIcon(color: SoyehtTheme.accentGreen, icon: "checkmark.circle")
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                                .offset(x: 12, y: -12)
                        )
                    appIcon(color: SoyehtTheme.accentRed.opacity(0.7), icon: "paintbrush")
                }
            }
        }
    }

    private func appIcon(color: Color, icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .frame(width: 52, height: 52)
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(SoyehtTheme.buttonTextOnAccent)
        }
    }
}
