import SwiftUI
import SoyehtCore

/// Carousel card 2 — isolated agents and protected private files.
struct CardSecurityByDesign: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedAgentCount = 0
    @State private var shieldActive = false

    private let agents: [IsolatedSecurityAgent] = [
        IsolatedSecurityAgent(
            assetName: "OnboardingOpenClaw",
            color: BrandColors.accentGreen,
            imageContentScale: 1.22
        ),
        IsolatedSecurityAgent(
            assetName: "OnboardingPi",
            color: BrandColors.accentGreen,
            imageContentScale: 1.18
        ),
        IsolatedSecurityAgent(
            assetName: "OnboardingHermes",
            color: BrandColors.accentGreen,
            imageContentScale: 1.05,
            imageBackground: .white
        ),
        IsolatedSecurityAgent(
            assetName: "OnboardingNanoclaw",
            color: BrandColors.accentGreen,
            imageContentScale: 1.36
        )
    ]

    var body: some View {
        CarouselCardLayout(
            illustration: securityIllustration,
            title: LocalizedStringResource(
                "carousel.cardSecurity.title",
                defaultValue: "Security by design",
                comment: "Carousel security card title."
            ),
            subtitle: LocalizedStringResource(
                "carousel.cardSecurity.subtitle",
                defaultValue: "A whole team of agents, safely isolated. Your private files stay protected.",
                comment: "Carousel security card subtitle."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.cardSecurity.a11y",
            defaultValue: "Security by design. A whole team of agents, safely isolated. Your private files stay protected.",
            comment: "VoiceOver combined label for carousel security card."
        )))
        .onAppear(perform: startAnimation)
    }

    private var securityIllustration: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    isolatedAgent(agent, index: index)
                }
            }

            protectedFiles
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(width: 324, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(BrandColors.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(BrandColors.border.opacity(0.72), lineWidth: 1)
        )
        .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(BrandColors.accentGreen.opacity(shieldActive || reduceMotion ? 0.32 : 0.16), lineWidth: 1)
                .frame(width: 292, height: 240)
                .shadow(color: BrandColors.accentGreen.opacity(shieldActive || reduceMotion ? 0.24 : 0.08), radius: 18)
                .animation(reduceMotion ? .none : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: shieldActive)
        }
    }

    private func isolatedAgent(_ agent: IsolatedSecurityAgent, index: Int) -> some View {
        let isVisible = reduceMotion || revealedAgentCount > index
        let isCurrent = !reduceMotion && revealedAgentCount == index + 1
        let imageMaskSize: CGFloat = 48

        return ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(agent.color.opacity(isVisible ? 0.9 : 0.22), lineWidth: 1.2)
                )
                .shadow(color: agent.color.opacity(isCurrent ? 0.4 : 0.16), radius: isCurrent ? 14 : 8)

            VStack(spacing: 6) {
                ZStack {
                    if let imageBackground = agent.imageBackground {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(imageBackground)
                            .frame(width: imageMaskSize, height: imageMaskSize)
                    }

                    Image(agent.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: imageMaskSize * agent.imageContentScale,
                            height: imageMaskSize * agent.imageContentScale
                        )
                }
                .frame(width: imageMaskSize, height: imageMaskSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(agent.color.opacity(0.7))
                    .frame(width: 22, height: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 15, height: 15)
                .background(agent.color)
                .clipShape(Circle())
                .padding(5)
                .opacity(isVisible ? 1 : 0)
        }
        .frame(width: 68, height: 80)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.88)
        .offset(y: isVisible ? 0 : 10)
    }

    private var protectedFiles: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .frame(width: 198, height: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(BrandColors.accentGreen.opacity(0.8), lineWidth: 1.2)
                )
                .shadow(color: BrandColors.accentGreen.opacity(shieldActive || reduceMotion ? 0.28 : 0.14), radius: 22)

            Image(systemName: "shield.fill")
                .font(.system(size: 104, weight: .semibold))
                .foregroundColor(BrandColors.accentGreen.opacity(shieldActive || reduceMotion ? 0.2 : 0.08))
                .offset(y: reduceMotion ? -2 : (shieldActive ? -7 : -2))
                .animation(reduceMotion ? .none : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: shieldActive)

            VStack(spacing: 10) {
                HStack(spacing: -7) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundColor(BrandColors.accentGreen.opacity(0.95))
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(BrandColors.textPrimary)
                }

                Image(systemName: "lock.fill")
                    .font(.system(size: 19, weight: .bold))
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(width: 40, height: 40)
                .background(BrandColors.accentGreen)
                .clipShape(Circle())
            }
        }
    }

    private func startAnimation() {
        guard !reduceMotion else {
            revealedAgentCount = agents.count
            shieldActive = true
            return
        }

        revealedAgentCount = 0
        shieldActive = false

        for index in 0..<agents.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.22) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    revealedAgentCount = index + 1
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(agents.count) * 0.22 + 0.16) {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                shieldActive = true
            }
        }
    }
}

private struct IsolatedSecurityAgent: Identifiable {
    let assetName: String
    let color: Color
    var imageContentScale: CGFloat = 1
    var imageBackground: Color? = nil

    var id: String { assetName }
}
