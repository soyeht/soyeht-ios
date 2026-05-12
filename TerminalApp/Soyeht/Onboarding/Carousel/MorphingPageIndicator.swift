import SwiftUI
import SoyehtCore

/// Morphing page indicator where the active dot stretches toward the next (T086a, FR-102).
/// Uses `AnimationCatalog.carouselPageDot`. Supports RTL/LTR correctly via layout direction.
struct MorphingPageIndicator: View {
    let pageCount: Int
    let currentPage: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private let dotSize: CGFloat = 8
    private let activeDotWidth: CGFloat = 22
    private let spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? BrandColors.accentGreen : BrandColors.border)
                    .frame(
                        width: index == currentPage ? activeDotWidth : dotSize,
                        height: dotSize
                    )
                    .animation(
                        AnimationCatalog.carouselPageDot(reduceMotion: reduceMotion),
                        value: currentPage
                    )
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.indicator.a11y",
            defaultValue: "Page \(currentPage + 1) of \(pageCount)",
            comment: "VoiceOver label for carousel page indicator."
        )))
        .environment(\.layoutDirection, layoutDirection)
    }
}
