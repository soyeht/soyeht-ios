import SwiftUI
import SoyehtCore

/// What the roster is allowed to say to the user, and nothing else.
///
/// **Payload-free by construction.** Both cases are dataless. The verified
/// roster carries machine ids, certificate fingerprints, canonical snapshot
/// bytes, tombstones and an engine outcome string; none of that can reach the
/// view layer through this type, because there is no associated value to reach
/// through. That is a stronger guarantee than "the view happens not to render
/// it today" — a future banner edit cannot leak what it cannot name.
///
/// **Two states are visible, four are silent.** A banner is an interruption, so
/// it is reserved for conditions the user must act on or must not trust:
///
/// - `.unknown` means "nothing established yet", which includes the ordinary
///   case where no roster activator was ever injected. Alarming on it would put
///   a permanent warning on every device that has not run the roster step.
/// - `.current` is the healthy state.
/// - `.degraded` is retryable and never touches persistence — transport blips,
///   an attested "cannot answer", or a store that refused a write. Surfacing it
///   would train the user to dismiss the banner that matters.
/// - `.terminalFork` is a real security condition, but the recovery story for it
///   is not designed yet and this slice deliberately ships no half-answer: an
///   alert with no correct action is worse than silence. It stays visible in
///   `RosterCoordinatorState` and is covered by the exhaustive switch below, so
///   giving it a presentation later is a one-line, test-forced change.
enum RosterAlertPresentation: Equatable {
    /// The owner provably retired the machine this device pinned. Actionable:
    /// the user re-pairs from Settings.
    case rePairRequired
    /// The roster did not hold up against the household root. Not actionable by
    /// the user, and deliberately not offered as a re-pair — see
    /// `offersSettingsAction`.
    case unverifiable

    /// EXHAUSTIVE ON PURPOSE — no `default`. Adding a case to
    /// `RosterCoordinatorState` must break this build until someone decides,
    /// deliberately, whether the user should be interrupted by it. A catch-all
    /// would silently default new states to "say nothing", which is exactly the
    /// failure mode a security banner cannot afford.
    ///
    /// No case binds its associated value, so nothing is destructured, copied,
    /// or carried out of the coordinator's state.
    static func resolve(_ state: RosterCoordinatorState) -> RosterAlertPresentation? {
        switch state {
        case .unknown, .current, .degraded, .terminalFork:
            return nil
        case .requiresRePairing:
            return .rePairRequired
        case .tamperSuspected:
            return .unverifiable
        }
    }

    /// Identity-gated resolution — the single decision point both household
    /// surfaces use, so the home screen and the instance list cannot drift
    /// apart on when a roster banner is allowed to appear.
    ///
    /// With no active identity there is no home for the roster to speak about,
    /// so nothing is shown regardless of what the runtime still holds. The gate
    /// is explicit rather than inherited from `stop()` publishing `.unknown`:
    /// that is a teardown side effect, and a teardown change that stopped
    /// clearing the state would silently resurrect a stale banner on an
    /// unauthenticated screen with no test noticing.
    static func resolve(
        _ state: RosterCoordinatorState,
        identityActive: Bool
    ) -> RosterAlertPresentation? {
        guard identityActive else { return nil }
        return resolve(state)
    }

    /// `.unverifiable` gets no call to action on purpose.
    ///
    /// `RosterEvidenceCoordinator` only ever reaches `requiresRePairing` by
    /// verifying an owner-signed revocation against the household root key.
    /// Every unproven condition — including the anchor mismatch an attacker can
    /// provoke — lands in `tamperSuspected` instead. Offering "re-pair" from
    /// there would hand that attacker the exact prompt the coordinator refuses
    /// to hand them. The banner tells the user something is wrong and stops.
    var offersSettingsAction: Bool {
        switch self {
        case .rePairRequired:
            return true
        case .unverifiable:
            return false
        }
    }
}

/// Standing notice about the household's verified device list.
///
/// Receives an already-resolved presentation — never the coordinator state, the
/// household, or the runtime — so the resolution decision has exactly one home
/// and this view has nothing to leak. Copy is inline `LocalizedStringResource`
/// with `defaultValue`, so the string catalog stays frozen for this slice.
///
/// The banner never navigates on its own: `onSettings` is the caller's existing
/// Settings action, so no new route, reset, QR gate, or endpoint read is
/// introduced here.
struct RosterAlertBanner: View {
    let presentation: RosterAlertPresentation
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typography.sansCard)
                .foregroundColor(accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Typography.monoBodySemi)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if presentation.offersSettingsAction {
                    Button(action: onSettings) {
                        Text(LocalizedStringResource(
                            "household.rosterAlert.rePairRequired.action",
                            defaultValue: "Open Settings",
                            comment: "Call to action on the household roster banner shown when this home must be paired again. Opens the Settings sheet the home screen already presents."
                        ))
                        .font(Typography.monoSmallMedium)
                        .foregroundColor(SoyehtTheme.accentLink)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(SoyehtTheme.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentColor.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var accentColor: Color {
        switch presentation {
        case .rePairRequired:
            return SoyehtTheme.accentAmber
        case .unverifiable:
            return SoyehtTheme.accentRed
        }
    }

    private var title: LocalizedStringResource {
        switch presentation {
        case .rePairRequired:
            return LocalizedStringResource(
                "household.rosterAlert.rePairRequired.title",
                defaultValue: "This home needs pairing again",
                comment: "Title of the household roster banner shown after the owner retired the device that signs this home's list of devices."
            )
        case .unverifiable:
            return LocalizedStringResource(
                "household.rosterAlert.unverifiable.title",
                defaultValue: "Can't verify this home's devices",
                comment: "Title of the household roster banner shown when the signed device list did not hold up against this home's owner key."
            )
        }
    }

    private var message: LocalizedStringResource {
        switch presentation {
        case .rePairRequired:
            return LocalizedStringResource(
                "household.rosterAlert.rePairRequired.body",
                defaultValue: "The device that keeps this home's list of devices was retired by its owner. Pair this home again to keep it up to date.",
                comment: "Body of the household roster banner shown after an owner-signed retirement. Deliberately names no device, person, or address."
            )
        case .unverifiable:
            return LocalizedStringResource(
                "household.rosterAlert.unverifiable.body",
                defaultValue: "Soyeht could not confirm this home's list of devices. Nothing on this iPhone was changed. Try again later.",
                comment: "Body of the household roster banner shown when verification failed. Offers no action on purpose, because no user action is known to be safe here."
            )
        }
    }
}
