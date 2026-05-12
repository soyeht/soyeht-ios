import SwiftUI
import SoyehtCore

/// 5-card welcome carousel (T080, FR-020, FR-021).
/// Shows on first launch; CTA on last card fires `onComplete`.
/// Respects Reduce Motion (FR-082), VoiceOver (FR-080), Dynamic Type.
struct CarouselRootView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 5

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    CardClawStore()
                        .tag(0)
                    CardAgentTeams()
                        .tag(1)
                    CardAgentAsSite()
                        .tag(2)
                    CardVoice()
                        .tag(3)
                    CardMacAndIphone()
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(
                    reduceMotion ? .none : AnimationCatalog.sceneTransition(reduceMotion: false),
                    value: currentPage
                )

                MorphingPageIndicator(pageCount: pageCount, currentPage: currentPage)
                    .padding(.bottom, 20)

                ctaBar
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var ctaBar: some View {
        VStack(spacing: 0) {
            if currentPage < pageCount - 1 {
                // Next page button
                Button(action: {
                    if reduceMotion { currentPage += 1 } else { withAnimation { currentPage += 1 } }
                }) {
                    Text(LocalizedStringResource(
                        "carousel.next",
                        defaultValue: "Next",
                        comment: "Carousel next page button."
                    ))
                    .font(OnboardingFonts.bodyBold)
                    .foregroundColor(BrandColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(BrandColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .transition(.opacity)

                Button(action: completedTapped) {
                    Text(LocalizedStringResource(
                        "carousel.skip",
                        defaultValue: "Skip tour",
                        comment: "Carousel skip button — bypasses remaining cards."
                    ))
                    .font(OnboardingFonts.footnote)
                    .foregroundColor(BrandColors.textMuted)
                }
                .padding(.bottom, 20)
            } else {
                // Final CTA — Liquid Glass variant where available (T086b)
                Button(action: completedTapped) {
                    HStack(spacing: 10) {
                        Text(LocalizedStringResource(
                            "carousel.cta",
                            defaultValue: "Let's start",
                            comment: "Carousel final CTA. Celebratory, forward-looking."
                        ))
                        .font(OnboardingFonts.bodyBold)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .buttonStyle(HapticButtonStyle(haptic: .ctaTap, animation: AnimationCatalog.buttonPress(reduceMotion: reduceMotion)))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: currentPage)
    }

    private func completedTapped() {
        CarouselSeenStorage().markSeen()
        TelemetryClient().track(.carouselCompleted)
        onComplete()
    }
}

// MARK: - HapticButtonStyle

private struct HapticButtonStyle: ButtonStyle {
    let haptic: HapticDirector.Profile
    let animation: Animation

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(animation, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { HapticDirector.live().fire(self.haptic) }
            }
    }
}
