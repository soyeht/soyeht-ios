import SwiftUI
import SoyehtCore

/// Renders a `HouseAvatar` as an emoji centered in an HSL-colored circle.
///
/// Never recomputes the avatar on the render path — `avatar` is persisted at
/// house creation and passed in (FR-046). Initial-reveal animation is applied
/// once via `T050a` (`AnimationCatalog.avatarReveal`).
struct HouseAvatarView: View {
    let avatar: HouseAvatar
    /// Diameter of the circular background. Default 88pt.
    var diameter: CGFloat = 88
    /// When true, plays the scale-in + glow reveal animation (FR-103).
    var animateReveal: Bool = false

    @State private var revealed = false
    @State private var glowOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            glowHalo

            Text(String(avatar.emoji))
                .font(.system(size: diameter * 0.55))
                .frame(width: diameter, height: diameter)
                .background(avatarBackground)
                .clipShape(Circle())
                .scaleEffect(animateReveal ? (revealed ? 1.0 : 0.6) : 1.0)
                .opacity(animateReveal ? (revealed ? 1.0 : 0.0) : 1.0)
        }
        .onAppear {
            guard animateReveal else { return }
            withAnimation(AnimationCatalog.avatarReveal(reduceMotion: reduceMotion)) {
                revealed = true
            }
            withAnimation(.easeInOut(duration: AnimationCatalog.Duration.avatarRevealGlow)
                .delay(0.1)) {
                glowOpacity = 0.6
            }
            withAnimation(.easeOut(duration: 0.3)
                .delay(0.1 + AnimationCatalog.Duration.avatarRevealGlow)) {
                glowOpacity = 0
            }
            // Fire haptic at animation apex (FR-112): ~0.5s for spring, ~0.2s for reduce motion.
            let apexDelay: TimeInterval = reduceMotion ? 0.2 : 0.5
            Task {
                try? await Task.sleep(for: .seconds(apexDelay))
                HapticDirector.live().fire(.avatarLanded)
            }
        }
        .accessibilityLabel(Text(String(avatar.emoji)))
        .accessibilityHidden(false)
    }

    private var avatarBackground: Color {
        hslToColor(h: Double(avatar.colorH), s: Double(avatar.colorS), l: Double(avatar.colorL))
    }

    private var glowHalo: some View {
        Circle()
            .fill(avatarBackground.opacity(0.3))
            .frame(width: diameter * 1.35, height: diameter * 1.35)
            .opacity(glowOpacity)
            .accessibilityHidden(true)
    }

    /// Converts HSL (degrees, percent, percent) to SwiftUI Color via HSB.
    private func hslToColor(h: Double, s: Double, l: Double) -> Color {
        let sNorm = s / 100.0
        let lNorm = l / 100.0
        let c = (1 - abs(2 * lNorm - 1)) * sNorm
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lNorm - c / 2

        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case 0..<60:   (r1, g1, b1) = (c, x, 0)
        case 60..<120: (r1, g1, b1) = (x, c, 0)
        case 120..<180:(r1, g1, b1) = (0, c, x)
        case 180..<240:(r1, g1, b1) = (0, x, c)
        case 240..<300:(r1, g1, b1) = (x, 0, c)
        default:       (r1, g1, b1) = (c, 0, x)
        }

        return Color(
            red: r1 + m,
            green: g1 + m,
            blue: b1 + m
        )
    }
}
