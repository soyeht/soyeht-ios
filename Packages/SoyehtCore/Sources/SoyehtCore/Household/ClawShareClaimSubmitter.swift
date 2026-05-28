import Foundation

/// Pluggable transport for the friend-side claim ceremony.
///
/// The Rust `friend-cli` ships a real Nostr relay submitter (publish
/// encrypted `ClawShareClaim` → subscribe ack on a pinned set of WSS
/// relays). On iOS the same protocol exists, but the production-shipped
/// implementation is intentionally a no-op stub
/// (`iOSRelayUnavailableClaimSubmitter`) that fails honestly with
/// `.iosClaimRelayNotYetWired`. The HTTP submitter is kept ONLY for
/// dev/test paths where the friend can reach the engine directly
/// (LAN, simulator, Tailscale ts-net).
///
/// Wiring contract:
/// - `ClawShareInviteCenter.shared` MUST use
///   `iOSRelayUnavailableClaimSubmitter` in production builds. This is
///   enforced by `ClawShareInviteCenterTests.testProductionSubmitterIsNotHTTP`.
/// - Dev/test code injects `HTTPClawShareClaimSubmitter` explicitly.
public protocol ClawShareClaimSubmitter: Sendable {
    /// Submit the claim ceremony for `invite` using a guest identity
    /// minted by `identityProvider`. Returns a `ClaimedSession` on
    /// success or throws a typed `ClawShareError`.
    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession
}

/// Production default on iOS. Always fails fast — the friend's iPhone
/// has no vetted way to publish the encrypted claim over Nostr WSS
/// yet, so we refuse to ship a path that pretends the claim went
/// through and quietly drops on the floor. See
/// `docs/household-protocol.md` for the planned Swift Nostr stack.
public struct iOSRelayUnavailableClaimSubmitter: ClawShareClaimSubmitter {
    public init() {}

    public func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        _ = invite
        _ = identityProvider
        throw ClawShareError.iosClaimRelayNotYetWired
    }
}

/// Dev/test submitter that wraps `ClawShareHTTPClient.performClaim`.
/// Requires the friend's device to reach `engineBase` directly. Not
/// suitable for cross-network production scenarios.
public struct HTTPClawShareClaimSubmitter: ClawShareClaimSubmitter {
    private let engineBase: URL
    private let session: URLSession

    public init(engineBase: URL, session: URLSession = .shared) {
        self.engineBase = engineBase
        self.session = session
    }

    public func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        try await ClawShareHTTPClient.performClaim(
            invite: invite,
            engineBase: engineBase,
            session: session,
            identityProvider: identityProvider
        )
    }
}
