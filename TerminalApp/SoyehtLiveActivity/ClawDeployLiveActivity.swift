import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Colors (duplicated from SoyehtTheme — widget runs in separate process)

private let accentGreen = Color(red: 0x00/255, green: 0xD9/255, blue: 0xA3/255)
private let warningAmber = Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
private let bgPrimary = Color(red: 0x0A/255, green: 0x0A/255, blue: 0x0A/255)
private let textSecondary = Color(red: 0x6B/255, green: 0x6B/255, blue: 0x6B/255)

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
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundColor(.white)

            if phase == .ready {
                Text(specsString(context.attributes))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(textSecondary)
            } else if let msg = context.state.message {
                Text(msg)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
            }
        }

        Spacer()

        switch phase {
        case .queuing, .pulling, .starting:
            Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(accentGreen)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentGreen)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(warningAmber)
        }
    }
    .padding(16)
    .background(bgPrimary)
}

// MARK: - Compact

@ViewBuilder
private func compactLeading(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Image(systemName: "clock")
            .foregroundColor(textSecondary)
    case .pulling:
        ProgressView()
            .tint(.white)
            .scaleEffect(0.7)
    case .starting:
        ProgressView()
            .tint(accentGreen)
            .scaleEffect(0.7)
    case .ready:
        Image(systemName: "checkmark.circle.fill")
            .foregroundColor(accentGreen)
    case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(warningAmber)
    }
}

@ViewBuilder
private func compactTrailing(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Text("Queuing...")
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(textSecondary)
    case .pulling:
        Text("Pulling...")
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.white)
    case .starting:
        Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundColor(accentGreen)
            .monospacedDigit()
            .frame(width: 40)
    case .ready:
        Text("Ready")
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundColor(accentGreen)
    case .failed:
        Text("Failed")
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(warningAmber)
    }
}

// MARK: - Minimal

@ViewBuilder
private func minimal(context: ActivityViewContext<ClawDeployAttributes>) -> some View {
    let phase = DeployPhase(status: context.state.status, phase: context.state.phase)

    switch phase {
    case .queuing:
        Image(systemName: "clock")
            .foregroundColor(textSecondary)
    case .pulling, .starting:
        ProgressView()
            .tint(accentGreen)
            .scaleEffect(0.7)
    case .ready:
        Image(systemName: "checkmark.circle.fill")
            .foregroundColor(accentGreen)
    case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(warningAmber)
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
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundColor(.white)

            Spacer()

            switch phase {
            case .queuing:
                phaseBadge("Queuing", color: textSecondary)
            case .pulling, .starting:
                Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundColor(.white)
                    .monospacedDigit()
            case .ready:
                phaseBadge("Ready", color: accentGreen, filled: true)
            case .failed:
                phaseBadge("Failed", color: warningAmber)
            }
        }

        switch phase {
        case .queuing:
            Text(context.attributes.clawName)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(.white)
            Text(context.attributes.clawType)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(textSecondary)

        case .pulling:
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundColor(accentGreen)
                if let msg = context.state.message {
                    Text(msg)
                        .font(.system(.subheadline, design: .monospaced))
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
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

        case .ready:
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentGreen.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(accentGreen)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.clawName)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundColor(.white)
                    Text(specsString(context.attributes))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(textSecondary)
                }
            }

        case .failed:
            if let msg = context.state.message {
                Text(msg)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(warningAmber)
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
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
            if let msg = context.state.message {
                Text(msg)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(textSecondary)
            }
            Spacer()
            Text(timerInterval: context.attributes.startDate...Date(), countsDown: false)
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundColor(textSecondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }

    case .pulling, .starting:
        Text(context.attributes.clawName)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(textSecondary)

    case .ready:
        HStack {
            Spacer()
            Text("Tap to connect")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(accentGreen)
            Spacer()
        }
        .padding(.vertical, 6)
        .background(accentGreen.opacity(0.1))
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
            .fill(accentGreen)
            .frame(width: size, height: size)
        Image(systemName: "terminal")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundColor(.black)
    }
}

@ViewBuilder
private func phaseBadge(_ text: String, color: Color, filled: Bool = false) -> some View {
    Text(text)
        .font(.system(.caption2, design: .monospaced).bold())
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
