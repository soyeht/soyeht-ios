import SwiftUI
import SoyehtCore

/// Renders the "this Mac can't be reached for Claws" copy when the
/// `ClawInstallTargetResolver` returns `.unavailable(.missingContext)`.
/// This is now a network/endpoint failure, not a normal state for Macs
/// paired through the household flow.
struct MacClawUnavailableView: View {
    let serverDisplayName: String?
    let onBack: () -> Void

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Text(verbatim: "<")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.accentGreen)
                    }
                    Text("clawstore.title")
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(Typography.monoBody)
                            .foregroundColor(SoyehtTheme.accentAmber)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringResource(
                                "clawstore.unavailable.macEndpoint.title",
                                defaultValue: "This Mac cannot be reached for Claw management",
                                comment: "Title shown when iPhone cannot derive or reach the selected Mac's household Claw endpoint."
                            ))
                                .font(Typography.monoCardTitle)
                                .foregroundColor(SoyehtTheme.textPrimary)
                            if let serverDisplayName {
                                Text(LocalizedStringResource(
                                    "clawstore.unavailable.macEndpoint.bodyNamed",
                                    defaultValue:
                                        "\(serverDisplayName) is paired, but Soyeht does not have a usable network address for its Claw endpoint yet. Other paired servers continue to work.",
                                    comment: "Body shown when a Mac has no usable household endpoint. %@ = server display name."
                                ))
                                    .font(Typography.monoLabelRegular)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(LocalizedStringResource(
                                    "clawstore.unavailable.macEndpoint.body",
                                    defaultValue: "This Mac is paired, but Soyeht does not have a usable network address for its Claw endpoint yet. Other paired servers continue to work.",
                                    comment: "Body (unnamed variant) shown when a Mac has no usable household endpoint."
                                ))
                                    .font(Typography.monoLabelRegular)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SoyehtTheme.bgPrimary)
                .overlay(Rectangle().stroke(SoyehtTheme.accentAmberStrong, lineWidth: 1))

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .navigationBarHidden(true)
        .accessibilityIdentifier(AccessibilityID.ClawStore.macUnavailableState)
    }
}
