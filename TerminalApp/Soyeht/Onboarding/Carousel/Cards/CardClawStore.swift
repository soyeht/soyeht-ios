import SwiftUI
import SoyehtCore

/// Carousel card 1 — Claw Store (T081, US3).
struct CardClawStore: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedClawCount = 1

    private let imageCornerRadius: CGFloat = 14

    private let claws: [OnboardingClawTile] = [
        OnboardingClawTile(
            title: "openclaw",
            assetName: "OnboardingOpenClaw",
            background: Color(hex: "#04100A"),
            border: BrandColors.accentGreen,
            imageScale: 0.82
        ),
        OnboardingClawTile(
            title: "pi",
            assetName: "OnboardingPi",
            background: Color(hex: "#04100A"),
            border: BrandColors.accentGreen,
            imageScale: 0.78,
            imageContentScale: 1.15
        ),
        OnboardingClawTile(
            title: "hermes",
            assetName: "OnboardingHermes",
            background: Color(hex: "#04100A"),
            border: BrandColors.accentGreen,
            imageScale: 0.74,
            imageBackground: .white
        ),
        OnboardingClawTile(
            title: "nanoclaw",
            assetName: "OnboardingNanoclaw",
            background: Color(hex: "#04100A"),
            border: BrandColors.accentGreen,
            imageScale: 0.78,
            imageContentScale: 2.08
        )
    ]

    var body: some View {
        CarouselCardLayout(
            illustration: clawIllustration,
            title: LocalizedStringResource(
                "carousel.card1.title",
                defaultValue: "Explore\nthe Claw Store",
                comment: "Carousel card 1 title: Claw Store."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card1.subtitle",
                defaultValue: "One agent is never enough. Visit the Claw Store and spin up agents with a single tap.",
                comment: "Carousel card 1 subtitle: describes Claw Store."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card1.a11y",
            defaultValue: "Explore the Claw Store. One agent is never enough. Visit the Claw Store and spin up agents with a single tap.",
            comment: "VoiceOver combined label for carousel card 1."
        )))
    }

    private var clawIllustration: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width, 345)
            let tileWidth = min((contentWidth - 12) / 2, 166.5)
            let tileHeight = tileWidth * 1.255

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    clawTile(claws[0], index: 0, width: tileWidth, height: tileHeight)
                    clawTile(claws[1], index: 1, width: tileWidth, height: tileHeight)
                }

                HStack(spacing: 12) {
                    clawTile(claws[2], index: 2, width: tileWidth, height: tileHeight)
                    clawTile(claws[3], index: 3, width: tileWidth, height: tileHeight)
                }
            }
            .frame(width: tileWidth * 2 + 12, height: tileHeight * 2 + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, 24)
        .frame(height: 430)
        .onAppear(perform: playRevealAnimation)
        .onChange(of: reduceMotion) { _ in
            playRevealAnimation()
        }
    }

    private func clawTile(_ claw: OnboardingClawTile, index: Int, width: CGFloat, height: CGFloat) -> some View {
        let isRevealed = reduceMotion || revealedClawCount > index
        let isCurrentReveal = !reduceMotion && revealedClawCount == index + 1
        let imageSize = min(width * claw.imageScale, height * 0.62)
        let imageBackgroundSize = imageSize * 1.06

        return VStack(spacing: 0) {
            Spacer(minLength: 12)

            ZStack {
                if let imageBackground = claw.imageBackground {
                    RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        .fill(imageBackground)
                        .frame(width: imageBackgroundSize, height: imageBackgroundSize)
                }

                Image(claw.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize * claw.imageContentScale, height: imageSize * claw.imageContentScale)
            }
            .frame(
                width: claw.imageBackground == nil ? imageSize : imageBackgroundSize,
                height: claw.imageBackground == nil ? imageSize : imageBackgroundSize
            )
            .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)

            Text(claw.title)
                .font(.system(size: max(8, width * 0.055), weight: .semibold))
                .foregroundColor(BrandColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(claw.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(claw.border, lineWidth: 1)
        )
        .shadow(
            color: claw.border.opacity(isCurrentReveal ? 0.55 : 0.32),
            radius: isCurrentReveal ? 24 : 18
        )
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(isRevealed ? 1 : 0.86)
        .offset(y: isRevealed ? 0 : 14)
    }

    private func playRevealAnimation() {
        guard !reduceMotion else {
            revealedClawCount = claws.count
            return
        }

        revealedClawCount = 1
        for index in 1..<claws.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.34) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    revealedClawCount = index + 1
                }
            }
        }
    }
}

private struct OnboardingClawTile: Identifiable {
    let title: String
    let assetName: String
    let background: Color
    let border: Color
    let imageScale: CGFloat
    var imageContentScale: CGFloat = 1
    var imageBackground: Color? = nil

    var id: String { assetName }
}
