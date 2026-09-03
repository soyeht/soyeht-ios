import SoyehtCore
import SwiftUI

/// I5 — the moment the phone and the Mac become one home.
///
/// The old flow celebrated in three screens (success, biometric confirm,
/// recovery message) that the person who set the Mac up never saw, because
/// the first-owner path skipped straight past them. This is one screen, it is
/// shown to everybody who pairs — by radar, by QR, by link — and it carries
/// nothing else.
///
/// It carried a "Protect with Face ID" switch for a while. That switch
/// enrolled an owner passkey, and on a real device it could never succeed:
/// the engine wires its WebAuthn relying party and rollback anchor into a
/// macOS-local Unix-socket router only, so the HTTP endpoint the phone talks
/// to answers every enrollment with `credential_anchor_invalid` and every
/// status check with `missing_anchor_verifier`. (The relying-party id is also
/// the placeholder `household.example.test`, which no app is associated with.)
/// A switch that always fails is worse than no switch on the screen that says
/// the setup worked. It comes back when the engine can enroll from the phone.
struct PairedCelebrationView: View {
    let snapshot: SoyehtIdentitySnapshot
    let macName: String?
    let onOpenTerminal: () -> Void

    private let palette = NeoPalette.cloud

    var body: some View {
        OnboardingScaffold(palette: palette) {
            VStack(spacing: 20) {
                check

                Text(title)
                    .font(NeoFont.title)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "onboarding.paired.body",
                    defaultValue: "This iPhone is part of your home now. Your sessions run on the Mac and open here.",
                    comment: "I5 body — what pairing actually bought."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(action: onOpenTerminal) {
                Text(LocalizedStringResource(
                    "onboarding.paired.cta",
                    defaultValue: "Open a terminal",
                    comment: "I5 primary button — into the home."
                ))
            }
            .buttonStyle(NeoPillButtonStyle(.primary, palette: palette))
            .accessibilityIdentifier(AccessibilityID.Onboarding.pairedContinue)
        }
    }

    private var title: String {
        guard let macName, !macName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(
                localized: "onboarding.paired.title.generic",
                defaultValue: "Your Mac is yours.",
                comment: "I5 title when the Mac's name is not known yet."
            )
        }
        return String(
            localized: "onboarding.paired.title",
            defaultValue: "\(macName) is yours.",
            comment: "I5 title. %@ = the Mac's name."
        )
    }

    private var check: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(palette.success)
            .frame(width: 96, height: 96)
            .neoRaised(palette, radius: NeoRadius.card, elevation: .hero)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }
}
