import SwiftUI
import SoyehtCore

/// Carrossel card 4 — Voz é mais rápido (T084, US3).
struct CardVoice: View {
    @State private var waveAmplitudes: [CGFloat] = [0.3, 0.6, 1.0, 0.6, 0.3]
    @State private var animating = false

    var body: some View {
        CarouselCardLayout(
            illustration: voiceIllustration,
            title: LocalizedStringResource(
                "carousel.card4.title",
                defaultValue: "Voz é mais rápido",
                comment: "Carousel card 4 title: voice commands."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card4.subtitle",
                defaultValue: "Fale com seus agentes. Mais natural que digitar, mais preciso que clicar.",
                comment: "Carousel card 4 subtitle: voice is natural and precise."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card4.a11y",
            defaultValue: "Voz é mais rápido. Fale com seus agentes — mais natural que digitar.",
            comment: "VoiceOver combined label for carousel card 4."
        )))
        .onAppear { startWaveAnimation() }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var voiceIllustration: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(BrandColors.accentGreen.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "mic.fill")
                    .font(.system(size: 44))
                    .foregroundColor(BrandColors.accentGreen)
            }

            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BrandColors.accentGreen)
                        .frame(width: 6, height: 30 * (reduceMotion ? 0.6 : waveAmplitudes[i]))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.5)
                                .delay(Double(i) * 0.1)
                                .repeatForever(autoreverses: true),
                            value: animating
                        )
                }
            }
            .frame(height: 40)
        }
    }

    private func startWaveAnimation() {
        guard !reduceMotion else { return }
        animating = true
        waveAmplitudes = [0.8, 1.0, 0.7, 1.0, 0.8]
    }
}
