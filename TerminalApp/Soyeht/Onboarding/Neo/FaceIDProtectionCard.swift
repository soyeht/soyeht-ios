import SoyehtCore
import SwiftUI

#if canImport(AuthenticationServices)

/// "Protect with Face ID", as one switch on the celebration screen.
///
/// What the switch actually does is enroll an owner passkey. The Secure
/// Enclave key this iPhone pairs with has its access control fixed at pairing
/// time — it is pinned inside the `PersonCert` — so there is no biometric
/// setting to flip afterwards. The passkey is the mechanism that *is*
/// reversible, has a view-model with real phases, and degrades on a simulator
/// with no biometrics.
///
/// It never blocks the way out: the CTA under this card is live whether the
/// switch is on, off, or mid-ceremony, and a card that cannot be built at all
/// (no owner key, no AuthenticationServices) simply is not drawn.
struct FaceIDProtectionCard: View {
    @ObservedObject var model: OwnerPasskeyEnrollmentViewModel
    let palette: NeoPalette

    var body: some View {
        card(model)
    }

    private func card(_ model: OwnerPasskeyEnrollmentViewModel) -> some View {
        NeoCard(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { isOn(model.phase) },
                    set: { wanted in
                        guard wanted else {
                            model.setUpLater()
                            return
                        }
                        Task { await model.enroll() }
                    }
                )) {
                    Text(LocalizedStringResource(
                        "onboarding.paired.faceID.title",
                        defaultValue: "Protect with Face ID",
                        comment: "I5: the label of the switch that enrolls an owner passkey."
                    ))
                    .font(NeoFont.body)
                    .foregroundStyle(palette.text)
                }
                .toggleStyle(NeoToggleStyle(palette: palette))
                .disabled(model.phase == .enrolling)
                .accessibilityIdentifier(AccessibilityID.Onboarding.faceIDToggle)

                Text(subtitle(model.phase))
                    .font(NeoFont.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    private func isOn(_ phase: OwnerPasskeyEnrollmentViewModel.Phase) -> Bool {
        switch phase {
        case .completed: return true
        case .enrolling: return true
        case .idle, .skipped, .failed: return false
        }
    }

    private func subtitle(_ phase: OwnerPasskeyEnrollmentViewModel.Phase) -> LocalizedStringResource {
        switch phase {
        case .completed:
            return LocalizedStringResource(
                "onboarding.paired.faceID.protected",
                defaultValue: "Protected. Face ID confirms it's you when this iPhone approves changes to your home.",
                comment: "I5: the switch is on and the passkey is enrolled."
            )
        case .enrolling:
            return LocalizedStringResource(
                "onboarding.paired.faceID.enrolling",
                defaultValue: "Setting it up…",
                comment: "I5: the passkey ceremony is on screen."
            )
        case .failed:
            return LocalizedStringResource(
                "onboarding.paired.faceID.failed",
                defaultValue: "That didn't finish. You can turn it on later in Settings.",
                comment: "I5: the ceremony was cancelled or failed; never a dead end."
            )
        case .idle, .skipped:
            return LocalizedStringResource(
                "onboarding.paired.faceID.body",
                defaultValue: "Ask for Face ID when this iPhone approves changes to your home. You can turn it on later.",
                comment: "I5: what the switch buys, and that it is optional."
            )
        }
    }

}

#endif
