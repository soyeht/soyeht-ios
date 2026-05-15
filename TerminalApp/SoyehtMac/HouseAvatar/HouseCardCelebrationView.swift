import SwiftUI
import SoyehtCore

/// Overlaid celebration effect when the first resident iPhone is added to the house.
/// 4–6 emoji-sticker particles burst outward + fade (FR-104). Total ≤1.2s.
/// Reduce Motion fallback: simple cross-fade with no movement.
struct HouseCardCelebrationView: View {
    let onComplete: () -> Void

    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Particle {
        let emoji: String
        let angleDeg: Double
        let distance: CGFloat
        let delay: Double
    }

    private let particles: [Particle] = [
        Particle(emoji: "🎉", angleDeg: -65, distance: 80, delay: 0.00),
        Particle(emoji: "✨", angleDeg: 0,   distance: 90, delay: 0.06),
        Particle(emoji: "⭐️", angleDeg: 65,  distance: 75, delay: 0.12),
        Particle(emoji: "🎊", angleDeg: -25, distance: 85, delay: 0.04),
        Particle(emoji: "💫", angleDeg: 30,  distance: 70, delay: 0.08),
    ]

    var body: some View {
        ZStack {
            ForEach(particles.indices, id: \.self) { idx in
                particleView(particles[idx])
            }
        }
        .allowsHitTesting(false)
        .task { await animate() }
    }

    @ViewBuilder
    private func particleView(_ p: Particle) -> some View {
        let rad = p.angleDeg * Double.pi / 180
        Text(p.emoji)
            .font(.system(size: 22))
            .offset(
                x: burst ? p.distance * CGFloat(cos(rad)) : 0,
                y: burst ? -p.distance * CGFloat(sin(rad)) : 0
            )
            .opacity(burst ? 0 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.3)
                    : AnimationCatalog.confettiBurst(reduceMotion: false).delay(p.delay),
                value: burst
            )
    }

    private func animate() async {
        burst = true
        let totalDuration = reduceMotion ? 0.3 : AnimationCatalog.Duration.confettiBurst
        try? await Task.sleep(for: .seconds(totalDuration))
        onComplete()
    }
}
