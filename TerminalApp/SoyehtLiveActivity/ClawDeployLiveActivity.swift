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

// MARK: - Lock Screen Banner

@ViewBuilder
private func lockScreenBanner(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    HStack(spacing: 12) {
        appIcon(size: 28)

        VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.clawName)
                .font(Typography.monoSubheadlineBold)
                .foregroundColor(.white)

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
                .frame(width: 44, alignment: .trailing)
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
    .padding(16)
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
            .tint(.white)
            .scaleEffect(0.7)
    case .starting:
        ProgressView()
            .tint(BrandColors.accentGreen)
            .scaleEffect(0.7)
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
            .foregroundColor(.white)
    case .starting:
        Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
            .font(Typography.monoCaption2Bold)
            .foregroundColor(BrandColors.accentGreen)
            .monospacedDigit()
            .frame(width: 40)
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
            .scaleEffect(0.7)
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
    appIcon(size: 28)
}

@ViewBuilder
private func expandedCenter(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
            Text("soyeht")
                .font(Typography.monoSubheadlineBold)
                .foregroundColor(.white)

            Spacer()

            switch phase {
            case .queuing:
                phaseBadge("Queuing", color: BrandColors.textMuted)
            case .pulling, .starting:
                Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                    .font(Typography.monoTitle3Bold)
                    .foregroundColor(.white)
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
                .foregroundColor(.white)
            Text(context.attributes.clawType)
                .font(Typography.monoCaption)
                .foregroundColor(BrandColors.textMuted)

        case .pulling:
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(Typography.sansCard)
                    .foregroundColor(BrandColors.accentGreen)
                if let msg = context.state.message {
                    Text(msg)
                        .font(Typography.monoSubheadline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.6)
                if let msg = context.state.message {
                    Text(msg)
                        .font(Typography.monoSubheadline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

        case .ready:
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(BrandColors.accentGreen.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(Typography.iconStatusBold)
                        .foregroundColor(BrandColors.accentGreen)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.clawName)
                        .font(Typography.monoSubheadlineBold)
                        .foregroundColor(.white)
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
        HStack(spacing: 4) {
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
                .frame(width: 36, alignment: .trailing)
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
        .padding(.vertical, 6)
        .background(BrandColors.accentGreen.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))

    case .failed:
        EmptyView()
    }
}

// MARK: - Helpers

@ViewBuilder
private func appIcon(size: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(BrandColors.accentGreen)
            .frame(width: size, height: size)
        Image(systemName: "terminal")
            .font(Typography.sans(size: Typography.clampedUISize(size * 0.5), weight: .bold))
            .foregroundColor(.black)
    }
}

@ViewBuilder
private func phaseBadge(_ text: String, color: Color, filled: Bool = false) -> some View {
    Text(text)
        .font(Typography.monoCaption2Bold)
        .foregroundColor(filled ? color : color.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(filled ? color.opacity(0.15) : Color.white.opacity(0.08))
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
