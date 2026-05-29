import Foundation
import SoyehtCore
import SwiftUI
import os

/// App-scoped, observable wrapper around `ClawShareInviteRouter`.
///
/// Owns the production identity provider (Secure Enclave-backed
/// `deviceIdentity()`), the claim submitter, and the published state
/// the SwiftUI sheet observes. The router itself is an `actor`, so
/// this class is the single place we hop between actor and UI thread.
///
/// **Apple-grade gating:** the center NEVER surfaces a state that
/// implies an openable session. The highest state visible after a
/// successful claim is `.acceptedAwaitingDataPlane`, mapped to copy
/// like "Almost ready — this share isn't openable yet". No
/// "connected", "open terminal", or "tap to enter" affordance lives
/// on this code path.
///
/// **Transport honesty:** the production submitter is
/// `iOSRelayUnavailableClaimSubmitter`, which fails fast with
/// `.iosClaimRelayNotYetWired`. The UI then surfaces a truthful
/// "this share method isn't supported on iPhone yet" message. Dev/test
/// builds may inject `HTTPClawShareClaimSubmitter` for a direct path.
@MainActor
final class ClawShareInviteCenter: ObservableObject {
    static let shared = ClawShareInviteCenter()

    @Published private(set) var state: ClawShareRouterState = .idle
    @Published private(set) var isSubmitting: Bool = false

    /// Drives the real "Open" gate once a credential is in hand. The sheet
    /// observes `openController.canOpen` to reveal Open and presents the
    /// terminal via `openController.launch`.
    let openController: ClawShareOpenController

    private let router: ClawShareInviteRouter
    let identityProvider: any ClawShareGuestIdentityProvider
    let claimSubmitter: any ClawShareClaimSubmitter
    private let logger = Logger(subsystem: "com.soyeht.mobile", category: "claw-share-center")
    /// Guards against re-dialing the engine on every `refresh()` — we only
    /// bring the session up once per distinct credential.
    private var preparedCredential: GuestCredential?

    nonisolated private static func makeProductionIdentityProvider() -> any ClawShareGuestIdentityProvider {
        SecureEnclaveClawShareGuestIdentityProvider.deviceIdentity()
    }

    init(
        router: ClawShareInviteRouter = ClawShareInviteRouter(),
        identityProvider: any ClawShareGuestIdentityProvider = makeProductionIdentityProvider(),
        claimSubmitter: any ClawShareClaimSubmitter = NostrClawShareClaimSubmitter()
    ) {
        self.router = router
        self.identityProvider = identityProvider
        self.claimSubmitter = claimSubmitter
        self.openController = ClawShareOpenController(identityProvider: identityProvider)
    }

    /// Test/preview seam: inject a pre-wired open controller (fake factory +
    /// stub signer + fixed endpoint) so the Open gate can be exercised
    /// off-device.
    init(
        router: ClawShareInviteRouter,
        identityProvider: any ClawShareGuestIdentityProvider,
        claimSubmitter: any ClawShareClaimSubmitter,
        openController: ClawShareOpenController
    ) {
        self.router = router
        self.identityProvider = identityProvider
        self.claimSubmitter = claimSubmitter
        self.openController = openController
    }

    @discardableResult
    func handleDeepLink(_ url: URL) async -> Bool {
        let consumed = await router.handle(url: url)
        await refresh()
        if consumed {
            logger.info("claw_share_deep_link_consumed url=\(url.absoluteString, privacy: .private)")
        }
        return consumed
    }

    func accept() async {
        guard !isSubmitting else { return }
        guard let invite = await router.accept() else {
            await refresh()
            return
        }
        isSubmitting = true
        await refresh()
        defer { Task { @MainActor in self.isSubmitting = false } }

        do {
            let session = try await claimSubmitter.submit(
                invite: invite,
                identityProvider: identityProvider
            )
            try await router.didReceiveAck(session)
            logger.info("claw_share_claim_acked claw=\(invite.clawId, privacy: .public)")
        } catch let error as ClawShareError {
            await router.didFail(error)
            logger.error("claw_share_claim_failed err=\(String(describing: error), privacy: .public)")
        } catch {
            await router.didFail(.transportClosed)
            logger.error("claw_share_claim_transport_error err=\(String(describing: error), privacy: .public)")
        }
        await refresh()
    }

    func decline() async {
        await router.reset()
        await refresh()
    }

    func acknowledgeFailure() async {
        await router.reset()
        await refresh()
    }

    private func refresh() async {
        let snapshot = await router.currentState()
        self.state = snapshot
        // Bring the real session up to the open gate the moment a credential
        // is in hand — exactly once per credential. If no endpoint is staged
        // the controller stays unavailable (honest "almost ready", no dial).
        if case .acceptedAwaitingDataPlane(let credential, _) = snapshot {
            if preparedCredential != credential {
                preparedCredential = credential
                let controller = openController
                Task { await controller.prepare(credential: credential) }
            }
        } else {
            preparedCredential = nil
        }
    }
}

#if DEBUG
extension ClawShareInviteCenter {
    static func makeForPreview() -> ClawShareInviteCenter {
        ClawShareInviteCenter(
            router: ClawShareInviteRouter(),
            identityProvider: EphemeralClawShareGuestIdentityProvider(),
            claimSubmitter: iOSRelayUnavailableClaimSubmitter()
        )
    }
}
#endif
