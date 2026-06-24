import SoyehtCore
import SwiftUI

/// P6-B/C: macOS Claw Store reason-coded recovery banner. Renders the native copy
/// from `MacGuestImageRecovery` for a readiness gate state with the shared-policy
/// CTA: a read-only "Check Again" (status re-fetch) for Mac-side blockers, or the
/// mutating "Try Again" (prepare, force) for on-device-recoverable codes. It
/// self-gates: nothing renders when install is allowed (`ready` / `notApplicable`).
/// The mutating CTA appears only when the policy says so — no blind retry.
struct MacGuestImageRecoveryBanner: View {
    let state: MacGuestImageGateState
    /// Read-only status re-fetch (`recheck()`).
    let onCheckAgain: () -> Void
    /// Mutating guest-image prepare (force) followed by an authoritative re-fetch.
    let onPrepare: () -> Void
    /// Disables the read-only CTA while a re-fetch is in flight.
    var isRechecking: Bool = false
    /// Disables the prepare CTA while a prepare is in flight.
    var isPreparing: Bool = false

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
                switch content.cta {
                case .prepare:
                    Button {
                        onPrepare()
                    } label: {
                        // E1c: a never-prepared Mac (`.notStarted`) reads "Prepare
                        // this Mac" (first run); a recoverable failure reads "Try
                        // Again". Both drive the same mutating `onPrepare`.
                        Text(content.kind == .notStarted
                            ? LocalizedStringResource(
                                "macClawStore.guestImage.action.prepareThisMac",
                                defaultValue: "Prepare this Mac",
                                comment: "macOS Claw Store CTA that starts guest-image preparation on a Mac that has not begun (mutating)."
                            )
                            : LocalizedStringResource(
                                "macClawStore.guestImage.action.tryAgain",
                                defaultValue: "Try Again",
                                comment: "macOS Claw Store CTA that re-invokes guest-image preparation (mutating)."
                            ))
                        .font(MacTypography.Fonts.clawActionButton)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)
                    .accessibilityIdentifier(content.kind == .notStarted
                        ? "soyeht.macClawStore.guestImage.prepareThisMac"
                        : "soyeht.macClawStore.guestImage.tryAgain")
                case .checkAgain:
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
                case .none:
                    EmptyView()
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
