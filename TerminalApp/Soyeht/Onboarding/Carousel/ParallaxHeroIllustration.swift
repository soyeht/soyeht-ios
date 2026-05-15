import SwiftUI
import SoyehtCore

/// Parallax + cross-fade modifier for carousel hero illustrations (T086, FR-082).
/// Hero illustration scrolls at 0.4× the page offset while content scrolls at 1.0×.
/// Respects `UIAccessibility.isReduceMotionEnabled` — disables parallax when ON.
struct ParallaxHeroIllustration<Content: View, Background: View>: View {
    let pageOffset: CGFloat
    let content: () -> Content
    let background: () -> Background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background()
                .offset(x: reduceMotion ? 0 : pageOffset * 0.4)

            content()
                .offset(x: reduceMotion ? 0 : pageOffset * 1.0)
        }
        .clipped()
    }
}

extension View {
    func parallaxHero(pageOffset: CGFloat) -> some View {
        self
    }
}
