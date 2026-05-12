import SwiftUI
import SoyehtCore

/// Carousel card 4 — Voice is faster (T084, US3).
struct CardVoice: View {
    @State private var waveAmplitudes: [CGFloat] = [0.3, 0.6, 1.0, 0.6, 0.3]
    @State private var animating = false

    var body: some View {
        CarouselCardLayout(
            illustration: voiceIllustration,
            title: LocalizedStringResource(
                "carousel.card4.title",
                defaultValue: "Voice is faster",
                comment: "Carousel card 4 title: voice commands."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card4.subtitle",
                defaultValue: "Talk to your agents, more natural than typing.",
                comment: "Carousel card 4 subtitle: voice is natural and precise."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card4.a11y",
            defaultValue: "Voice is faster. Talk to your agents, more natural than typing.",
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
