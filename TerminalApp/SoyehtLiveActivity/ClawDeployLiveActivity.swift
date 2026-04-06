import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Colors (duplicated from SoyehtTheme — widget runs in separate process)

private let accentGreen = Color(red: 0x10/255, green: 0xB9/255, blue: 0x81/255)
private let warningAmber = Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
private let bgPrimary = Color(red: 0x0A/255, green: 0x0A/255, blue: 0x0A/255)
private let textSecondary = Color(red: 0x6B/255, green: 0x6B/255, blue: 0x6B/255)

// MARK: - Live Activity Widget

struct ClawDeployLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClawDeployAttributes.self) { context in
            // Lock Screen Banner
            HStack(spacing: 12) {
                statusIcon(context.state.status, size: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.clawName)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundColor(.white)

                    if let msg = context.state.message {
                        Text(msg)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(textSecondary)
                            .lineLimit(1)
                    } else if context.state.status == "provisioning" {
                        Text("deploying \(context.attributes.clawType)...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(textSecondary)
                    }
                }

                Spacer()

                Text("[\(context.attributes.clawType)]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(accentGreen)
            }
            .padding(16)
            .background(bgPrimary)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal")
                        .font(.title3)
                        .foregroundColor(accentGreen)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.clawName)
                            .font(.system(.subheadline, design: .monospaced).bold())
                            .foregroundColor(.white)

                        if let msg = context.state.message {
                            Text(msg)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(textSecondary)
                                .lineLimit(1)
                        } else {
                            Text(statusLabel(context.state.status))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(textSecondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    statusIcon(context.state.status, size: 20)
                }
            } compactLeading: {
                Image(systemName: "terminal")
                    .foregroundColor(accentGreen)
            } compactTrailing: {
                statusIcon(context.state.status, size: 14)
            } minimal: {
                statusIcon(context.state.status, size: 14)
            }
        }
    }
}

// MARK: - Helpers

@ViewBuilder
private func statusIcon(_ status: String, size: CGFloat) -> some View {
    switch status {
    case "active":
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .foregroundColor(accentGreen)
    case "failed":
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size))
            .foregroundColor(warningAmber)
    default:
        ProgressView()
            .tint(accentGreen)
            .scaleEffect(size / 20)
    }
}

private func statusLabel(_ status: String) -> String {
    switch status {
    case "active": return "deployed successfully"
    case "failed": return "deployment failed"
    default: return "deploying..."
    }
}
