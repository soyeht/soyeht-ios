import SwiftUI
import SoyehtCore

/// The one permission macOS may ask for during setup, shown as a card next to
/// the progress bar rather than instead of it.
///
/// It also has to explain itself: "Login Items" is a macOS word, not something
/// the owner asked for, so the card says what it buys them.
struct LoginItemsApprovalCard: View {
    let stillWaiting: Bool
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    private let palette = NeoPalette.cloud

    var body: some View {
        NeoCard(palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource(
                    "bootstrap.approval.card.title",
                    defaultValue: "macOS needs your OK to keep Soyeht running",
                    comment: "M2: title of the inline Login Items approval card."
                ))
                .font(NeoFont.heading)
                .foregroundStyle(palette.text)

                Text(LocalizedStringResource(
                    "bootstrap.approval.card.body",
                    defaultValue: "Turn Soyeht on under Login Items. Without it, your agents stop the moment you close the app.",
                    comment: "M2: body of the inline Login Items approval card, in the owner's terms."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(action: onOpenSettings) {
                        Text(LocalizedStringResource(
                            "bootstrap.approval.card.openSettings",
                            defaultValue: "Open Settings",
                            comment: "M2: button that opens the Login Items pane."
                        ))
                    }
                    .buttonStyle(NeoPillButtonStyle(.primary, palette: palette, fillsWidth: false))
                    .accessibilityIdentifier(WelcomeAccessibilityID.m2OpenSettings)

                    Button(action: onRecheck) {
                        Text(LocalizedStringResource(
                            "bootstrap.approval.card.recheck",
                            defaultValue: "I turned it on",
                            comment: "M2: button that re-checks the approval without leaving the step."
                        ))
                    }
                    .buttonStyle(NeoPillButtonStyle(.secondary, palette: palette, fillsWidth: false))
                    .accessibilityIdentifier(WelcomeAccessibilityID.m2Recheck)
                }

                if stillWaiting {
                    Text(LocalizedStringResource(
                        "bootstrap.approval.card.waiting",
                        defaultValue: "Still waiting for the switch. Soyeht should be listed under Login Items.",
                        comment: "M2: shown when a re-check found the permission still off."
                    ))
                    .font(NeoFont.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier(WelcomeAccessibilityID.m2ApprovalCard)
    }
}
