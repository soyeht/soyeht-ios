import SwiftUI
import SoyehtCore

/// Carousel card 2 — Your agents work together (T082, US3).
struct CardAgentTeams: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedAgentCount = 0
    @State private var connectionPulse = false

    private let agents: [CodingAgentNode] = [
        CodingAgentNode(
            name: "Claude Code",
            assetName: "OnboardingClaudeCode",
            color: BrandColors.accentGreen,
            position: CGPoint(x: 163, y: 46)
        ),
        CodingAgentNode(
            name: "Codex",
            assetName: "OnboardingCodex",
            color: BrandColors.accentGreen,
            position: CGPoint(x: 286, y: 146)
        ),
        CodingAgentNode(
            name: "Droid",
            assetName: "OnboardingDroid",
            color: BrandColors.accentGreen,
            position: CGPoint(x: 163, y: 246)
        ),
        CodingAgentNode(
            name: "OpenCode",
            assetName: "OnboardingOpenCode",
            color: BrandColors.accentGreen,
            position: CGPoint(x: 40, y: 146)
        )
    ]

    private let centerPoint = CGPoint(x: 163, y: 146)

    var body: some View {
        CarouselCardLayout(
            illustration: agentNetworkIllustration,
            title: LocalizedStringResource(
                "carousel.card2.title",
                defaultValue: "Your agents work together",
                comment: "Carousel card 2 title: agent teams."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card2.subtitle",
                defaultValue: "Let them chat, split the work, and get things done as a team.",
                comment: "Carousel card 2 subtitle: describes agent collaboration."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card2.a11y",
            defaultValue: "Your agents work together. Let them chat, split the work, and get things done as a team.",
            comment: "VoiceOver combined label for carousel card 2."
        )))
        .onAppear(perform: startAnimation)
        .onChange(of: reduceMotion) { _ in
            startAnimation()
        }
    }

    private var agentNetworkIllustration: some View {
        ZStack {
            networkConnections

            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                agentNode(agent, index: index)
                    .position(agent.position)
            }

            soyehtNode
                .position(centerPoint)
        }
        .frame(width: 326, height: 292)
    }

    private var networkConnections: some View {
        ZStack {
            ForEach(connectionSegments.indices, id: \.self) { index in
                let segment = connectionSegments[index]
                ConnectionLine(
                    from: segment.from,
                    to: segment.to,
                    color: segment.color,
                    reduceMotion: reduceMotion,
                    isActive: connectionPulse,
                    delay: Double(index) * 0.16
                )
            }
        }
    }

    private var connectionSegments: [ConnectionSegment] {
        let centerConnections = agents.map {
            ConnectionSegment(from: centerPoint, to: $0.position, color: $0.color)
        }
        let ringConnections = agents.indices.map { index in
            let nextIndex = (index + 1) % agents.count
            return ConnectionSegment(
                from: agents[index].position,
                to: agents[nextIndex].position,
                color: BrandColors.accentGreen
            )
        }

        return ringConnections + centerConnections
    }

    private var soyehtNode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BrandColors.surfaceDeep.opacity(0.9))
                .frame(width: 82, height: 82)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BrandColors.accentGreen.opacity(0.9), lineWidth: 1.2)
                )
                .shadow(color: BrandColors.accentGreen.opacity(reduceMotion ? 0.24 : (connectionPulse ? 0.42 : 0.18)), radius: 22)

            Image("OnboardingSoyehtLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func agentNode(_ agent: CodingAgentNode, index: Int) -> some View {
        let isVisible = reduceMotion || revealedAgentCount > index

        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(BrandColors.surfaceDeep.opacity(0.86))
                    .frame(width: 66, height: 66)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(agent.color.opacity(0.92), lineWidth: 1.2)
                    )
                    .shadow(color: agent.color.opacity(isVisible ? 0.28 : 0.08), radius: 12)

                Image(agent.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            Text(agent.name)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(BrandColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 78)
        }
        .frame(width: 78, height: 88)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.86)
        .animation(reduceMotion ? .none : .spring(response: 0.36, dampingFraction: 0.82), value: revealedAgentCount)
    }

    private func startAnimation() {
        guard !reduceMotion else {
            revealedAgentCount = agents.count
            connectionPulse = true
            return
        }

        revealedAgentCount = 0
        connectionPulse = false

        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            revealedAgentCount = agents.count
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            withAnimation(.easeInOut(duration: 0.2)) {
                connectionPulse = true
            }
        }
    }
}

private struct CodingAgentNode: Identifiable {
    let name: String
    let assetName: String
    let color: Color
    let position: CGPoint

    var id: String { assetName }
}

private struct ConnectionSegment {
    let from: CGPoint
    let to: CGPoint
    let color: Color
}

private struct ConnectionLine: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let reduceMotion: Bool
    let isActive: Bool
    let delay: Double

    var body: some View {
        ZStack {
            connectionPath
                .stroke(
                    color.opacity(reduceMotion ? 0.5 : (isActive ? 0.24 : 0)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )

            if !reduceMotion && isActive {
                TimelineView(.animation) { timeline in
                    let progress = packetProgress(at: timeline.date)
                    let head = point(at: progress)
                    let trail = point(at: max(progress - 0.08, 0))

                    ZStack {
                        Circle()
                            .fill(color.opacity(0.22))
                            .frame(width: 11, height: 11)
                            .position(head)

                        Capsule()
                            .fill(color.opacity(0.36))
                            .frame(width: 14, height: 3)
                            .rotationEffect(lineAngle)
                            .position(trail)

                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .shadow(color: color.opacity(0.8), radius: 6)
                            .position(head)
                    }
                }
            }
        }
    }

    private var connectionPath: Path {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
    }

    private var lineAngle: Angle {
        .radians(atan2(to.y - from.y, to.x - from.x))
    }

    private func packetProgress(at date: Date) -> CGFloat {
        let duration = 1.55
        let rawProgress = (date.timeIntervalSinceReferenceDate + delay).truncatingRemainder(dividingBy: duration) / duration
        return CGFloat(rawProgress)
    }

    private func point(at progress: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
    }
}
