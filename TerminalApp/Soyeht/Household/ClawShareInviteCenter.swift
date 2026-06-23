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

    private let router: ClawShareInviteRouter
    let identityProvider: any ClawShareGuestIdentityProvider
    let claimSubmitter: any ClawShareClaimSubmitter
    private let logger = Logger(subsystem: "com.soyeht.mobile", category: "claw-share-center")

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
        await MainActor.run {
            self.state = snapshot
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
