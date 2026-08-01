import Foundation
import SoyehtCore

/// What a claimed share turned out to be.
///
/// The slot is consumed atomically at claim time, so a guest cannot claim once
/// to discover the resource and claim again to open it. The claim therefore
/// happens exactly once and the result is routed by what came back — which is
/// why this is a single call returning a discriminated value rather than a
/// `peek` followed by an `open`.
enum ClawShareOpenOutcome {
    case terminal(RelayStreamTerminalConfiguration)
    case clawSite(ClawSiteViewModel)
}

/// Claims a share invite and routes it to the surface that can render it.
struct ClawShareOpenRouter: Sendable {
    enum RouteError: Error, LocalizedError {
        case missingRelayStreamOffer
        case unsupportedResource(RelayStreamResource)

        var errorDescription: String? {
            switch self {
            case .missingRelayStreamOffer:
                return String(localized: "The invite did not include a relay stream offer.")
            case .unsupportedResource:
                return String(localized: "This invite is not something this screen can open.")
            }
        }
    }

    private let claimSubmitter: any ClawShareClaimSubmitter
    private let identityProvider: any ClawShareGuestIdentityProvider
    private let now: @Sendable () -> Date

    init(
        claimSubmitter: any ClawShareClaimSubmitter = NostrClawShareClaimSubmitter(),
        identityProvider: any ClawShareGuestIdentityProvider = SecureEnclaveClawShareGuestIdentityProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claimSubmitter = claimSubmitter
        self.identityProvider = identityProvider
        self.now = now
    }

    @MainActor
    func open(invite: ClawShareInvite) async throws -> ClawShareOpenOutcome {
        let claimed = try await claimSubmitter.submit(invite: invite, identityProvider: identityProvider)
        guard let offer = claimed.relayStreamOffer else {
            throw RouteError.missingRelayStreamOffer
        }

        switch offer.payload.resource {
        case .pty:
            let controller = RelayStreamOpenController(
                claimSubmitter: PreclaimedSubmitter(claimed: claimed),
                identityProvider: identityProvider
            )
            return .terminal(try await controller.open(invite: invite))
        case .clawSite:
            let opener = ClawSiteRelayStreamOpener(
                offer: offer,
                credential: claimed.credential,
                guestIdentity: claimed.guestIdentity
            )
            let model = ClawSiteViewModel(
                clawName: invite.clawId,
                provider: ClaimedClawSiteEndpointProvider(
                    bridge: ClawSiteHTTPBridge(opener: opener)
                )
            )
            return .clawSite(model)
        case .ipTunnel:
            // Not reachable from an invite claim: the per-Claw VPN data path
            // is entered through `verifyRelayStreamIPTunnelGuest`, which also
            // demands a Group audience, and is driven by the packet-tunnel
            // extension rather than this screen. Refused explicitly instead of
            // via a `default:` so that a future resource forces a decision
            // here rather than silently landing in whichever arm is last.
            throw RouteError.unsupportedResource(offer.payload.resource)
        }
    }
}

/// Replays an already-claimed session so the PTY path can reuse
/// `RelayStreamOpenController` without claiming a second time — the slot is
/// single-use, so a second real claim would be rejected.
private struct PreclaimedSubmitter: ClawShareClaimSubmitter {
    let claimed: ClaimedSession

    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        claimed
    }
}
