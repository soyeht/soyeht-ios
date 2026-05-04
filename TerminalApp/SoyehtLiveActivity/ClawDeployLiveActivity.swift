import ActivityKit
import WidgetKit
import SwiftUI
import SoyehtCore

// MARK: - Live Activity Widget

struct ClawDeployLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClawDeployAttributes.self) { context in
            // Lock Screen Banner. `.widgetURL` wires a tap on the banner to a
            // deep link that the main app's ContentView intercepts — in the
            // `.ready` state this navigates straight to the new instance,
            // skipping the default behavior of just reopening the app.
            lockScreenBanner(context: context)
                .widgetURL(deployWidgetURL(context: context))

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context: context)
                }

                DynamicIslandExpandedRegion(.center) {
                    expandedCenter(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context: context)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context)
                }
            } compactLeading: {
                compactLeading(context: context)
            } compactTrailing: {
                compactTrailing(context: context)
            } minimal: {
                minimal(context: context)
            }
        }
    }
}

private enum DeployActivityMetrics {
    static let bannerSpacing: CGFloat = 12
    static let bannerIconSize: CGFloat = 28
    static let bannerTextSpacing: CGFloat = 2
    static let bannerTimerWidth: CGFloat = 44
    static let bannerPadding: CGFloat = 16

    static let compactProgressScale: CGFloat = 0.7
    static let compactTimerWidth: CGFloat = 40

    static let expandedIconSize: CGFloat = 28
    static let expandedHeaderSpacing: CGFloat = 2
    static let expandedHeaderRowSpacing: CGFloat = 6
    static let expandedStatusRowSpacing: CGFloat = 6
    static let expandedProgressScale: CGFloat = 0.6
    static let readyStatusRowSpacing: CGFloat = 10
    static let readyStatusIconSize: CGFloat = 32
    static let readyStatusTextSpacing: CGFloat = 1

    static let bottomQueueSpacing: CGFloat = 4
    static let bottomQueueTimerWidth: CGFloat = 36
    static let readyActionVerticalPadding: CGFloat = 6
    static let readyActionCornerRadius: CGFloat = 12

    static let appIconCornerRatio: CGFloat = 0.28
    static let appIconSymbolRatio: CGFloat = 0.5

    static let badgeHorizontalPadding: CGFloat = 8
    static let badgeVerticalPadding: CGFloat = 3
}

// MARK: - Lock Screen Banner

@ViewBuilder
private func lockScreenBanner(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    HStack(spacing: DeployActivityMetrics.bannerSpacing) {
        appIcon(size: DeployActivityMetrics.bannerIconSize)

        VStack(alignment: .leading, spacing: DeployActivityMetrics.bannerTextSpacing) {
            Text(context.attributes.clawName)
                .font(Typography.monoSubheadlineBold)
                .foregroundColor(BrandColors.textPrimary)

            if phase == .ready {
                Text(specsString(context.attributes))
                    .font(Typography.monoCaption2)
                    .foregroundColor(BrandColors.textMuted)
            } else if let msg = context.state.message {
                Text(msg)
                    .font(Typography.monoCaption2)
                    .foregroundColor(BrandColors.textMuted)
                    .lineLimit(1)
            }
        }

        Spacer()

        switch phase {
        case .queuing, .pulling, .starting:
            Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                .font(Typography.monoCaptionBold)
                .foregroundColor(BrandColors.accentGreen)
                .frame(width: DeployActivityMetrics.bannerTimerWidth, alignment: .trailing)
                .monospacedDigit()
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(Typography.iconStatus)
                .foregroundColor(BrandColors.accentGreen)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typography.iconStatus)
                .foregroundColor(BrandColors.accentAmber)
        }
    }
    .padding(DeployActivityMetrics.bannerPadding)
    .background(BrandColors.surfaceDeep)
}

// MARK: - Compact

@ViewBuilder
private func compactLeading(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Image(systemName: "clock")
            .foregroundColor(BrandColors.textMuted)
    case .pulling:
        ProgressView()
            .tint(BrandColors.textPrimary)
            .scaleEffect(DeployActivityMetrics.compactProgressScale)
    case .starting:
        ProgressView()
            .tint(BrandColors.accentGreen)
            .scaleEffect(DeployActivityMetrics.compactProgressScale)
    case .ready:
        Image(systemName: "checkmark.circle.fill")
            .foregroundColor(BrandColors.accentGreen)
    case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(BrandColors.accentAmber)
    }
}

@ViewBuilder
private func compactTrailing(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Text("Queuing...")
            .font(Typography.monoCaption2)
            .foregroundColor(BrandColors.textMuted)
    case .pulling:
        Text("Pulling...")
            .font(Typography.monoCaption2)
            .foregroundColor(BrandColors.textPrimary)
    case .starting:
        Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
            .font(Typography.monoCaption2Bold)
            .foregroundColor(BrandColors.accentGreen)
            .monospacedDigit()
            .frame(width: DeployActivityMetrics.compactTimerWidth)
    case .ready:
        Text("Ready")
            .font(Typography.monoCaption2Bold)
            .foregroundColor(BrandColors.accentGreen)
    case .failed:
        Text("Failed")
            .font(Typography.monoCaption2)
            .foregroundColor(BrandColors.accentAmber)
    }
}

// MARK: - Minimal

@ViewBuilder
private func minimal(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Image(systemName: "clock")
            .foregroundColor(BrandColors.textMuted)
    case .pulling, .starting:
        ProgressView()
            .tint(BrandColors.accentGreen)
            .scaleEffect(DeployActivityMetrics.compactProgressScale)
    case .ready:
        Image(systemName: "checkmark.circle.fill")
            .foregroundColor(BrandColors.accentGreen)
    case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(BrandColors.accentAmber)
    }
}

// MARK: - Expanded Regions

@ViewBuilder
private func expandedLeading(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    appIcon(size: DeployActivityMetrics.expandedIconSize)
}

@ViewBuilder
private func expandedCenter(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    VStack(alignment: .leading, spacing: DeployActivityMetrics.expandedHeaderSpacing) {
        HStack(spacing: DeployActivityMetrics.expandedHeaderRowSpacing) {
            Text("soyeht")
                .font(Typography.monoSubheadlineBold)
                .foregroundColor(BrandColors.textPrimary)

            Spacer()

            switch phase {
            case .queuing:
                phaseBadge("Queuing", color: BrandColors.textMuted)
            case .pulling, .starting:
                Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                    .font(Typography.monoTitle3Bold)
                    .foregroundColor(BrandColors.textPrimary)
                    .monospacedDigit()
            case .ready:
                phaseBadge("Ready", color: BrandColors.accentGreen, filled: true)
            case .failed:
                phaseBadge("Failed", color: BrandColors.accentAmber)
            }
        }

        switch phase {
        case .queuing:
            Text(context.attributes.clawName)
                .font(Typography.monoTitle3Bold)
                .foregroundColor(BrandColors.textPrimary)
            Text(context.attributes.clawType)
                .font(Typography.monoCaption)
                .foregroundColor(BrandColors.textMuted)

        case .pulling:
            HStack(spacing: DeployActivityMetrics.expandedStatusRowSpacing) {
                Image(systemName: "arrow.down.circle")
                    .font(Typography.sansCard)
                    .foregroundColor(BrandColors.accentGreen)
                if let msg = context.state.message {
                    Text(msg)
                        .font(Typography.monoSubheadline)
                        .foregroundColor(BrandColors.textPrimary)
                        .lineLimit(1)
                }
            }

        case .starting:
            HStack(spacing: DeployActivityMetrics.expandedStatusRowSpacing) {
                ProgressView()
                    .tint(BrandColors.textPrimary)
                    .scaleEffect(DeployActivityMetrics.expandedProgressScale)
                if let msg = context.state.message {
                    Text(msg)
                        .font(Typography.monoSubheadline)
                        .foregroundColor(BrandColors.textPrimary)
                        .lineLimit(1)
                }
            }

        case .ready:
            HStack(spacing: DeployActivityMetrics.readyStatusRowSpacing) {
                ZStack {
                    Circle()
                        .fill(BrandColors.selection)
                        .frame(
                            width: DeployActivityMetrics.readyStatusIconSize,
                            height: DeployActivityMetrics.readyStatusIconSize
                        )
                    Image(systemName: "checkmark")
                        .font(Typography.iconStatusBold)
                        .foregroundColor(BrandColors.accentGreen)
                }
                VStack(alignment: .leading, spacing: DeployActivityMetrics.readyStatusTextSpacing) {
                    Text(context.attributes.clawName)
                        .font(Typography.monoSubheadlineBold)
                        .foregroundColor(BrandColors.textPrimary)
                    Text(specsString(context.attributes))
                        .font(Typography.monoCaption2)
                        .foregroundColor(BrandColors.textMuted)
                }
            }

        case .failed:
            if let msg = context.state.message {
                Text(msg)
                    .font(Typography.monoCaption)
                    .foregroundColor(BrandColors.accentAmber)
                    .lineLimit(2)
            }
        }
    }
}

@ViewBuilder
private func expandedTrailing(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    EmptyView()
}

@ViewBuilder
private func expandedBottom(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        HStack(spacing: DeployActivityMetrics.bottomQueueSpacing) {
            Image(systemName: "clock")
                .font(Typography.sansSmall)
                .foregroundColor(BrandColors.textMuted)
            if let msg = context.state.message {
                Text(msg)
                    .font(Typography.monoCaption2)
                    .foregroundColor(BrandColors.textMuted)
            }
            Spacer()
            Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                .font(Typography.monoCaption2Bold)
                .foregroundColor(BrandColors.textMuted)
                .monospacedDigit()
                .frame(width: DeployActivityMetrics.bottomQueueTimerWidth, alignment: .trailing)
        }

    case .pulling, .starting:
        Text(context.attributes.clawName)
            .font(Typography.monoCaption2)
            .foregroundColor(BrandColors.textMuted)

    case .ready:
        HStack {
            Spacer()
            Text("Tap to connect")
                .font(Typography.monoCaptionBold)
                .foregroundColor(BrandColors.accentGreen)
            Spacer()
        }
        .padding(.vertical, DeployActivityMetrics.readyActionVerticalPadding)
        .background(BrandColors.selection)
        .clipShape(RoundedRectangle(cornerRadius: DeployActivityMetrics.readyActionCornerRadius))

    case .failed:
        EmptyView()
    }
}

// MARK: - Helpers

@ViewBuilder
private func appIcon(size: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: size * DeployActivityMetrics.appIconCornerRatio)
            .fill(BrandColors.accentGreen)
            .frame(width: size, height: size)
            Image(systemName: "terminal")
                .font(Typography.sans(
                    size: Typography.clampedUISize(size * DeployActivityMetrics.appIconSymbolRatio),
                    weight: .bold
                ))
            .foregroundColor(BrandColors.buttonTextOnAccent)
    }
}

@ViewBuilder
private func phaseBadge(_ text: String, color: Color, filled: Bool = false) -> some View {
    Text(text)
        .font(Typography.monoCaption2Bold)
        .foregroundColor(color)
        .padding(.horizontal, DeployActivityMetrics.badgeHorizontalPadding)
        .padding(.vertical, DeployActivityMetrics.badgeVerticalPadding)
        .background(filled ? BrandColors.selection : BrandColors.card)
        .clipShape(Capsule())
}

private func specsString(_ attrs: ClawDeployAttributes) -> String {
    let ram = attrs.ramMB >= 1024 ? "\(attrs.ramMB / 1024) GB" : "\(attrs.ramMB) MB"
    return "\(attrs.cpuCores) cores \u{00B7} \(ram) \u{00B7} \(attrs.diskGB) GB"
}

/// Deep link used by the Live Activity's widgetURL. The main app handles
/// `theyos://instance/<id>` in `ContentView.onOpenURL`, navigating to the
/// instance list and auto-opening the given instance's session sheet.
/// We emit a link for both in-progress and ready states — before ready,
/// tap just reopens the app on the instance list (soft landing); after
/// ready, tap navigates straight into the session sheet for the new VM.
private func deployWidgetURL(context: ActivityViewContext<ClawDeployAttributes>) -> URL? {
    URL(string: "theyos://instance/\(context.attributes.instanceId)")
}
