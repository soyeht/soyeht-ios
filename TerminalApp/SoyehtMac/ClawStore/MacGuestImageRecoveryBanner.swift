import SwiftUI

/// P6-B: macOS Claw Store reason-coded recovery banner. Renders the native copy
/// from `MacGuestImageRecovery` for a readiness gate state, with a read-only
/// "Check Again" CTA (status re-fetch). It self-gates: nothing is rendered when
/// install is allowed (`ready` / `notApplicable`). No mutating prepare CTA in
/// this slice — that is a follow-up.
struct MacGuestImageRecoveryBanner: View {
    let state: MacGuestImageGateState
    /// Read-only status re-fetch (`recheck()`); never a prepare retry.
    let onCheckAgain: () -> Void
    /// Disables the CTA while a re-fetch is already in flight.
    var isRechecking: Bool = false

    var body: some View {
        if let content = MacGuestImageRecovery.banner(for: state) {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.title)
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textPrimary)
                if let body = content.body {
                    Text(body)
                        .font(MacTypography.Fonts.clawDetailMeta)
                        .foregroundColor(MacClawStoreTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let instruction = content.instruction {
                    Text(instruction)
                        .font(MacTypography.Fonts.clawDetailMeta)
                        .foregroundColor(MacClawStoreTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if content.showsCheckAgain {
                    Button {
                        onCheckAgain()
                    } label: {
                        Text(LocalizedStringResource(
                            "macClawStore.guestImage.action.checkAgain",
                            defaultValue: "Check Again",
                            comment: "macOS Claw Store CTA that re-fetches this Mac's readiness (read-only, no prepare)."
                        ))
                        .font(MacTypography.Fonts.clawActionButton)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRechecking)
                    .accessibilityIdentifier("soyeht.macClawStore.guestImage.checkAgain")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(MacClawStoreTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MacClawStoreTheme.accentAmber, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("soyeht.macClawStore.readinessBanner")
        }
    }
}
