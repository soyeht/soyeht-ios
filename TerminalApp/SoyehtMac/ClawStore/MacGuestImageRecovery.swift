import Foundation
import SoyehtCore

/// P6-B: macOS-native reason-coded recovery content for the Claw Store guest-image
/// gate. AppKit-free (Foundation + SoyehtCore) so it is unit-testable in the
/// `SoyehtMacDomain` swift-test package. It consumes the SHARED
/// ``GuestImageRecoveryPolicy`` for the action/CTA semantics (no rule duplication)
/// and supplies macOS-native copy. The mutating "Prepare / Try Again" CTA is
/// intentionally NOT offered here — this slice exposes only the read-only
/// "Check Again" (status re-fetch); a prepare retry is a separate follow-up.
struct MacGuestImageBannerContent: Equatable {
    enum Kind: Equatable {
        case checking
        case preparing
        case failed(GuestImageFailureCode?)
        case unavailable
    }

    let kind: Kind
    let title: LocalizedStringResource
    let body: LocalizedStringResource?
    /// What to do on the Mac (only for some failure codes).
    let instruction: LocalizedStringResource?
    /// Whether to show the read-only "Check Again" CTA. Never a mutating prepare.
    let showsCheckAgain: Bool
}

enum MacGuestImageRecovery {
    /// The banner to render for a macOS readiness gate state, or `nil` when no
    /// banner is needed (install is allowed: `ready` / `notApplicable`).
    static func banner(for state: MacGuestImageGateState) -> MacGuestImageBannerContent? {
        switch state {
        case .allowed:
            // ready / notApplicable — install is open, no recovery banner.
            return nil

        case .checking:
            return MacGuestImageBannerContent(
                kind: .checking,
                title: LocalizedStringResource(
                    "macClawStore.guestImage.checking.title",
                    defaultValue: "Checking this Mac…",
                    comment: "macOS Claw Store banner while polling the engine's guest-image readiness."
                ),
                body: nil,
                instruction: nil,
                showsCheckAgain: false
            )

        case .unavailable:
            // Fail-closed: install stays gated, but the only CTA is a read-only
            // re-fetch — never a blind prepare retry.
            return MacGuestImageBannerContent(
                kind: .unavailable,
                title: LocalizedStringResource(
                    "macClawStore.guestImage.unavailable.title",
                    defaultValue: "Can't check this Mac right now",
                    comment: "macOS Claw Store banner when the engine's readiness can't be reached."
                ),
                body: LocalizedStringResource(
                    "macClawStore.guestImage.unavailable.body",
                    defaultValue: "Installs stay unavailable until this Mac can be reached.",
                    comment: "macOS Claw Store body when readiness can't be fetched."
                ),
                instruction: nil,
                showsCheckAgain: true
            )

        case .blocked(let readiness):
            guard let presentation = GuestImageRecoveryPolicy.presentation(for: readiness) else {
                // Defensive: ready/notApplicable should not reach `.blocked`.
                return nil
            }
            if presentation.isPreparing {
                return MacGuestImageBannerContent(
                    kind: .preparing,
                    title: LocalizedStringResource(
                        "macClawStore.guestImage.preparing.title",
                        defaultValue: "Preparing this Mac…",
                        comment: "macOS Claw Store banner while the engine builds its guest image."
                    ),
                    body: LocalizedStringResource(
                        "macClawStore.guestImage.preparing.body",
                        defaultValue: "Install isn't available until the guest image is ready.",
                        comment: "macOS Claw Store body while the guest image is preparing."
                    ),
                    instruction: nil,
                    // Re-fetch to see progress; not a prepare retry.
                    showsCheckAgain: true
                )
            }
            // Failed: reason-coded copy. Check Again is offered whenever any
            // recovery is possible (cta != .none); for an unsupported Mac
            // (.none, e.g. ipsw_incompatible) there is nothing to re-check.
            return MacGuestImageBannerContent(
                kind: .failed(presentation.failureCode),
                title: failureTitle(presentation.failureCode),
                body: failureBody(presentation.failureCode),
                instruction: failureInstruction(presentation.failureCode),
                showsCheckAgain: presentation.cta != .none
            )
        }
    }

    // MARK: - Native macOS failure copy (parity with iOS GuestImageFailureCopy)

    static func failureTitle(_ code: GuestImageFailureCode?) -> LocalizedStringResource {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.hostVmLimitReached.title",
                defaultValue: "This Mac needs a restart before preparing",
                comment: "Title when guest-image prep failed because macOS hit its active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.helperMissing.title",
                defaultValue: "Finish setup on the Mac",
                comment: "Title when guest-image prep needs a setup step on the Mac."
            )
        case .insufficientDisk:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.insufficientDisk.title",
                defaultValue: "Not enough space on the Mac",
                comment: "Title when guest-image prep failed for lack of disk space."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.entitlementMissing.title",
                defaultValue: "Reinstall Soyeht on the Mac",
                comment: "Title when guest-image prep failed because the Mac install can't run VMs."
            )
        case .ipswDownloadFailed:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.ipswDownloadFailed.title",
                defaultValue: "Couldn't download the macOS image",
                comment: "Title when the macOS restore image download failed."
            )
        case .ipswIncompatible:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.ipswIncompatible.title",
                defaultValue: "This Mac isn't supported yet",
                comment: "Title when no compatible restore image exists for this Mac."
            )
        case .unknown:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.unknown.title",
                defaultValue: "Couldn't prepare this Mac",
                comment: "Generic title when guest-image prep failed for an unclassified reason."
            )
        }
    }

    static func failureBody(_ code: GuestImageFailureCode?) -> LocalizedStringResource {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.hostVmLimitReached.body",
                defaultValue: "macOS is still holding an earlier virtual machine. Restarting clears it.",
                comment: "Body explaining the macOS active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.helperMissing.body",
                defaultValue: "This Mac needs a quick setup step before it can prepare.",
                comment: "Body for the helper/setup-missing failure."
            )
        case .insufficientDisk:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.insufficientDisk.body",
                defaultValue: "Free up space on the Mac, then check again.",
                comment: "Body for the insufficient-disk failure."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.entitlementMissing.body",
                defaultValue: "This Mac's Soyeht install can't run virtual machines.",
                comment: "Body for the missing-entitlement failure."
            )
        case .ipswDownloadFailed:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.ipswDownloadFailed.body",
                defaultValue: "Check the Mac's connection, then check again.",
                comment: "Body for the restore-image download failure."
            )
        case .ipswIncompatible:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.ipswIncompatible.body",
                defaultValue: "This Mac's macOS version isn't supported for preparation.",
                comment: "Body for the incompatible-restore-image failure."
            )
        case .unknown:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.unknown.body",
                defaultValue: "Something went wrong preparing this Mac.",
                comment: "Generic body when guest-image prep failed."
            )
        }
    }

    static func failureInstruction(_ code: GuestImageFailureCode?) -> LocalizedStringResource? {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.hostVmLimitReached.instruction",
                defaultValue: "Restart Soyeht on the Mac, or restart the Mac, then check again.",
                comment: "Instruction for clearing the macOS active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.helperMissing.instruction",
                defaultValue: "Open Soyeht on the Mac to finish setup, then check again.",
                comment: "Instruction for the helper/setup-missing failure."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "macClawStore.guestImage.failure.entitlementMissing.instruction",
                defaultValue: "Reinstall Soyeht on the Mac, then check again.",
                comment: "Instruction for the missing-entitlement failure."
            )
        case .insufficientDisk, .ipswDownloadFailed, .ipswIncompatible, .unknown:
            return nil
        }
    }
}
