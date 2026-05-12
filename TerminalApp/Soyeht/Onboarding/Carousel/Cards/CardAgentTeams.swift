import SwiftUI
import SoyehtCore

/// Carrossel card 2 — Times de agentes (T082, US3).
struct CardAgentTeams: View {
    @State private var rotation: Double = 0

    var body: some View {
        CarouselCardLayout(
            illustration: orbitIllustration,
            title: LocalizedStringResource(
                "carousel.card2.title",
                defaultValue: "Agent teams",
                comment: "Carousel card 2 title: agent teams."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card2.subtitle",
                defaultValue: "Agents work together to solve complex tasks automatically.",
                comment: "Carousel card 2 subtitle: describes agent collaboration."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card2.a11y",
            defaultValue: "Agent teams. Agents work together to solve complex tasks automatically.",
            comment: "VoiceOver combined label for carousel card 2."
        )))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var orbitIllustration: some View {
        ZStack {
            // Center core
            Circle()
                .fill(BrandColors.accentGreen)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "brain")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                )

            // Orbiting agents
            ForEach(0..<4, id: \.self) { i in
                orbitingDot(index: i)
            }
        }
        .frame(width: 180, height: 180)
        .rotationEffect(.degrees(reduceMotion ? 0 : rotation))
    }

    private func orbitingDot(index: Int) -> some View {
        let angle = Double(index) * 90
        let radius: CGFloat = 72
        let rad = angle * .pi / 180
        let icons = ["wand.and.stars", "chart.bar", "magnifyingglass", "doc.text"]
        return Circle()
            .fill(BrandColors.accentGreen.opacity(0.25))
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: icons[index])
                    .font(.system(size: 14))
                    .foregroundColor(BrandColors.accentGreen)
            )
            .offset(
                x: CGFloat(cos(rad)) * radius,
                y: CGFloat(sin(rad)) * radius
            )
    }
}
