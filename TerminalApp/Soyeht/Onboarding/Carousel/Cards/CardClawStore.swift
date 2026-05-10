import SwiftUI
import SoyehtCore

/// Carrossel card 1 — Loja Claw (T081, US3).
struct CardClawStore: View {
    var body: some View {
        CarouselCardLayout(
            illustration: clawIllustration,
            title: LocalizedStringResource(
                "carousel.card1.title",
                defaultValue: "Instale o que quiser",
                comment: "Carousel card 1 title: Claw store."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card1.subtitle",
                defaultValue: "A Loja Claw traz agentes, ferramentas e automações com um toque.",
                comment: "Carousel card 1 subtitle: describes Claw store."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card1.a11y",
            defaultValue: "Instale o que quiser. A Loja Claw traz agentes, ferramentas e automações com um toque.",
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
                    appIcon(color: BrandColors.accentGreen, icon: "cpu")
                    appIcon(color: Color.blue.opacity(0.7), icon: "mic")
                    appIcon(color: Color.purple.opacity(0.7), icon: "network")
                }
                HStack(spacing: 8) {
                    appIcon(color: Color.orange.opacity(0.7), icon: "calendar")
                    appIcon(color: BrandColors.accentGreen, icon: "checkmark.circle")
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .offset(x: 12, y: -12)
                        )
                    appIcon(color: Color.pink.opacity(0.7), icon: "paintbrush")
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
                .foregroundColor(.white)
        }
    }
}
