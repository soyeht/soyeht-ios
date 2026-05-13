import SwiftUI
import SoyehtCore

/// Carousel card 4 — Your computer, a server (T083, US3).
struct CardAgentAsSite: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedGroupCount = 0
    @State private var packetsActive = false

    private let centerPoint = CGPoint(x: 162, y: 140)
    private let audienceGroups: [AudienceGroup] = [
        AudienceGroup(
            color: BrandColors.accentGreen,
            position: CGPoint(x: 58, y: 62)
        ),
        AudienceGroup(
            color: BrandColors.accentGreen,
            position: CGPoint(x: 266, y: 62)
        ),
        AudienceGroup(
            color: BrandColors.accentGreen,
            position: CGPoint(x: 44, y: 184)
        ),
        AudienceGroup(
            color: BrandColors.accentGreen,
            position: CGPoint(x: 280, y: 184)
        ),
        AudienceGroup(
            color: BrandColors.accentGreen,
            position: CGPoint(x: 162, y: 258)
        )
    ]

    var body: some View {
        CarouselCardLayout(
            illustration: publishIllustration,
            title: LocalizedStringResource(
                "carousel.card3.title",
                defaultValue: "Your computer, a server",
                comment: "Carousel card 3 title: agent as website."
            ),
            subtitle: LocalizedStringResource(
                "carousel.card3.subtitle",
                defaultValue: "Publish any agent as a website anyone can reach.",
                comment: "Carousel card 3 subtitle: publish agent as a website."
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringResource(
            "carousel.card3.a11y",
            defaultValue: "Your computer, a server. Publish any agent as a website anyone can reach.",
            comment: "VoiceOver combined label for carousel card 3."
        )))
        .onAppear(perform: startAnimation)
        .onChange(of: reduceMotion) { _ in
            startAnimation()
        }
    }

    private var publishIllustration: some View {
        ZStack {
            publishingConnections

            ForEach(Array(audienceGroups.enumerated()), id: \.element.id) { index, group in
                audienceGroupNode(group, index: index)
                    .position(group.position)
            }

            publishedSite
                .position(centerPoint)
        }
        .frame(width: 324, height: 304)
    }

    private var publishingConnections: some View {
        ZStack {
            ForEach(audienceGroups.indices, id: \.self) { index in
                let group = audienceGroups[index]
                PublishingConnectionLine(
                    from: centerPoint,
                    to: group.position,
                    color: group.color,
                    reduceMotion: reduceMotion,
                    isActive: packetsActive,
                    delay: Double(index) * 0.2
                )
            }

            Circle()
                .stroke(BrandColors.accentGreen.opacity(0.13), lineWidth: 1)
                .frame(width: 198, height: 176)
        }
    }

    private var publishedSite: some View {
        ZStack {
            Circle()
                .fill(BrandColors.accentGreen.opacity(0.12))
                .frame(width: 126, height: 126)
                .shadow(color: BrandColors.accentGreen.opacity(packetsActive || reduceMotion ? 0.36 : 0.16), radius: 26)

            Circle()
                .stroke(BrandColors.accentGreen.opacity(0.42), lineWidth: 1.2)
                .frame(width: 104, height: 104)

            Circle()
                .stroke(BrandColors.accentGreen.opacity(0.18), lineWidth: 1)
                .frame(width: 156, height: 156)

            Image("OnboardingSoyehtLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 74, height: 74)
                .clipShape(Circle())

            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(width: 30, height: 30)
                .background(BrandColors.accentGreen)
                .clipShape(Circle())
                .offset(x: 42, y: 34)
        }
        .frame(width: 156, height: 156)
    }

    private func audienceGroupNode(_ group: AudienceGroup, index: Int) -> some View {
        let isVisible = reduceMotion || revealedGroupCount > index

        return ZStack {
            Circle()
                .fill(group.color.opacity(0.1))
                .frame(width: 84, height: 84)
                .shadow(color: group.color.opacity(isVisible ? 0.3 : 0.08), radius: 18)

            Circle()
                .stroke(group.color.opacity(0.74), lineWidth: 1.1)
                .frame(width: 74, height: 74)

            ZStack {
                personGlyph(color: group.color, size: 1)
                    .offset(y: -14)
                personGlyph(color: group.color, size: 0.78)
                    .offset(x: -21, y: 13)
                personGlyph(color: group.color, size: 0.78)
                    .offset(x: 21, y: 13)
            }
            .frame(width: 68, height: 56)
        }
        .frame(width: 88, height: 88)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.86)
        .offset(y: isVisible ? 0 : 10)
    }

    private func personGlyph(color: Color, size: CGFloat) -> some View {
        VStack(spacing: 4 * size) {
            Circle()
                .fill(color)
                .frame(width: 14 * size, height: 14 * size)

            Capsule()
                .fill(color.opacity(0.86))
                .frame(width: 19 * size, height: 14 * size)
        }
    }

    private func startAnimation() {
        guard !reduceMotion else {
            revealedGroupCount = audienceGroups.count
            packetsActive = true
            return
        }

        revealedGroupCount = 0
        packetsActive = false

        for index in 0..<audienceGroups.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    revealedGroupCount = index + 1
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(audienceGroups.count) * 0.2 + 0.12) {
            packetsActive = true
        }
    }
}

private struct AudienceGroup: Identifiable {
    let color: Color
    let position: CGPoint

    var id: String { "\(position.x)-\(position.y)" }
}

private struct PublishingConnectionLine: View {
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
                    color.opacity(reduceMotion ? 0.48 : 0.24),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )

            if !reduceMotion && isActive {
                TimelineView(.animation) { timeline in
                    let progress = packetProgress(at: timeline.date)
                    let head = point(at: progress)
                    let trail = point(at: max(progress - 0.08, 0))

                    ZStack {
                        Capsule()
                            .fill(color.opacity(0.36))
                            .frame(width: 16, height: 3)
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
        let duration = 1.45
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
