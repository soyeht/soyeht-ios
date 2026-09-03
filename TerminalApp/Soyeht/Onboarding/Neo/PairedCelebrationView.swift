import SoyehtCore
import SwiftUI
import os

private let celebrationLogger = Logger(subsystem: "com.soyeht.mobile", category: "onboarding-paired")

/// I5 — the moment the phone and the Mac become one home.
///
/// The old flow celebrated in three screens (success, biometric confirm,
/// recovery message) that the person who set the Mac up never saw, because
/// the first-owner path skipped straight past them. This is one screen, it is
/// shown to everybody who pairs — by radar, by QR, by link — and it carries
/// the single optional decision worth making here.
///
/// The CTA is never gated on the switch: a Face ID ceremony that is cancelled,
/// failing, or impossible still leaves a person one tap from their terminal.
struct PairedCelebrationView: View {
    let snapshot: SoyehtIdentitySnapshot
    let macName: String?
    let onOpenTerminal: () -> Void

    private let palette = NeoPalette.cloud

    #if canImport(AuthenticationServices)
    /// Built here rather than inside the card: reading the Secure Enclave and
    /// anchoring a passkey ceremony to a window are not things a body
    /// evaluation may do, and the screen — not the card — is what is
    /// definitely on screen to hang the work off.
    @State private var faceID: OwnerPasskeyEnrollmentViewModel?
    #endif

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

                #if canImport(AuthenticationServices)
                if let faceID {
                    FaceIDProtectionCard(model: faceID, palette: palette)
                        .padding(.top, 8)
                }
                #endif
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
        #if canImport(AuthenticationServices)
        .task {
            guard faceID == nil else { return }
            // `nil` means this device has no owner key to protect — the card
            // is simply not drawn, rather than showing a switch that cannot
            // work. Logged because a card that silently does not appear is
            // indistinguishable from one that was never written.
            let model = OwnerPasskeyEnrollmentComposer.makeViewModel(
                snapshot: snapshot,
                anchorProvider: KeyWindowPasskeyAnchorProvider()
            )
            celebrationLogger.info("paired.faceid_card available=\(model != nil, privacy: .public)")
            faceID = model
        }
        #endif
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
