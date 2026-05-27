import SwiftUI
import SoyehtCore

/// Renders the "this Mac can't be managed directly yet" copy when the
/// `ClawInstallTargetResolver` returns `.unavailable(.missingContext)`.
///
/// This is the multi-Mac-without-token regression PR-3 makes explicit:
/// rather than silently routing install to "some Mac" via the household
/// PoP path, we tell the user that *this* Mac needs a Soyeht update.
/// The product copy intentionally avoids any suggestion that the user
/// should re-pair via QR — that would imply their original pair was
/// wrong, which it wasn't.
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
                                "clawstore.unavailable.macNeedsUpdate.title",
                                defaultValue: "Direct Claw management is not available for this Mac yet",
                                comment: "Title shown when a Mac was paired but has no per-server token for direct Claw API calls."
                            ))
                                .font(Typography.monoCardTitle)
                                .foregroundColor(SoyehtTheme.textPrimary)
                            if let serverDisplayName {
                                Text(LocalizedStringResource(
                                    "clawstore.unavailable.macNeedsUpdate.bodyNamed",
                                    defaultValue:
                                        "\(serverDisplayName) needs a Soyeht update to manage Claws directly. Other paired servers continue to work.",
                                    comment: "Body shown when a Mac has no per-server token. %@ = server display name."
                                ))
                                    .font(Typography.monoLabelRegular)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(LocalizedStringResource(
                                    "clawstore.unavailable.macNeedsUpdate.body",
                                    defaultValue: "This Mac needs a Soyeht update to manage Claws directly. Other paired servers continue to work.",
                                    comment: "Body (unnamed variant) shown when a Mac has no per-server token."
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
