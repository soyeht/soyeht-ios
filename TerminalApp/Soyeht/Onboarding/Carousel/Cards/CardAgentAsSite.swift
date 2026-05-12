import SwiftUI
import SoyehtCore

/// Carrossel card 3 — Seu agente vira site (T083, US3).
struct CardAgentAsSite: View {
    @State private var visitorOpacities: [Double] = [0, 0, 0, 0, 0]

    var body: some View {
        CarouselCardLayout(
            illustration: broadcastIllustration,
            title: LocalizedStringResource(
                "carousel.card3.title",
                defaultValue: "Your agent becomes a site",
                comment: "Carousel card 3 title: agent as website."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card3.subtitle",
                defaultValue: "Publish your agent as a site anyone can access.",
                comment: "Carousel card 3 subtitle: publish agent as a website."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card3.a11y",
            defaultValue: "Your agent becomes a site. Publish your agent as a site anyone can access.",
            comment: "VoiceOver combined label for carousel card 3."
        )))
        .onAppear { animateVisitors() }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var broadcastIllustration: some View {
        ZStack {
            // Mac silhouette
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BrandColors.card)
                    .frame(width: 90, height: 60)
                    .overlay(
                        Image(systemName: "globe")
                            .font(.system(size: 28))
                            .foregroundColor(BrandColors.accentGreen)
                    )
                Rectangle()
                    .fill(BrandColors.border)
                    .frame(width: 40, height: 4)
                Rectangle()
                    .fill(BrandColors.border)
                    .frame(width: 60, height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Anonymous visitors
            ForEach(0..<5, id: \.self) { i in
                visitor(index: i)
            }
        }
        .frame(width: 200, height: 180)
    }

    private func visitor(index: Int) -> some View {
        let positions: [(x: CGFloat, y: CGFloat)] = [
            (-80, -50), (80, -50), (-90, 20), (90, 20), (0, 70)
        ]
        let pos = positions[index]
        return Image(systemName: "person.fill")
            .font(.system(size: 18))
            .foregroundColor(BrandColors.accentGreen.opacity(0.7))
            .offset(x: pos.x, y: pos.y)
            .opacity(visitorOpacities[index])
    }

    private func animateVisitors() {
        guard !reduceMotion else {
            visitorOpacities = [Double](repeating: 0.8, count: 5)
            return
        }
        for i in 0..<5 {
            withAnimation(.easeIn(duration: 0.4).delay(Double(i) * 0.25)) {
                visitorOpacities[i] = 0.8
            }
        }
    }
}
