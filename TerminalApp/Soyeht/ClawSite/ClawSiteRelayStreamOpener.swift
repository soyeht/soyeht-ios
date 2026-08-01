import Foundation
import RelayStreamGuestFFI
import SoyehtCore

/// Adapts one relay-stream guest session to the HTTP bridge's frame vocabulary.
///
/// The data plane's frame set is shaped for a PTY. Every kind is mapped
/// explicitly rather than defaulted, because the ones that look irrelevant here
/// are exactly the ones that must not be silently dropped: an `exitCode` or
/// `exitLost` is the backend going away, and treating it as "keep waiting"
/// would hang the request until the bridge timeout instead of failing fast.
struct ClawSiteRelayStreamSession: ClawSiteStreamSession {
    let session: RelayStreamGuestDataPlaneSession

    func send(_ data: Data) async throws {
        try await session.send(data: data)
    }

    func close() async throws {
        try await session.close()
    }

    func nextFrame() async throws -> ClawSiteStreamFrame {
        let frame = try await session.nextFrame()
        switch frame.kind {
        case .data:
            return .data(frame.data)
        case .close:
            return .closed
        case .error:
            return .failed(frame.text)
        case .exitCode, .exitSignal, .exitLost:
            // The claw's HTTP backend ended the stream. For a `Connection: close`
            // exchange that is a normal end-of-body, so it is `closed`, not a
            // failure — the bridge decides whether what arrived parses.
            return .closed
        case .open, .health, .window:
            // Transport-level chatter that carries no response bytes. Recurse
            // rather than returning, so the caller only ever sees frames that
            // advance the HTTP exchange.
            return try await nextFrame()
        }
    }
}

/// Opens a fresh authenticated relay-stream session per HTTP exchange, reusing
/// the offer and credential obtained once at claim time.
///
/// Re-dialing the same offer is by design: the invite slot was already consumed
/// atomically when the guest claimed it, and the relay's replay protection is
/// keyed on the per-dial auth nonce, which `prepareAuthSigningRequest` mints
/// fresh on every call. What is NOT reusable is a single stream — hence one
/// session per request.
struct ClawSiteRelayStreamOpener: ClawSiteStreamOpening {
    let offer: RelayStreamOfferContract
    let credential: GuestCredential
    let guestIdentity: any ClawShareGuestIdentity
    let client: RelayStreamGuestDataPlaneClient
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> UUID
    let ttlSecs: UInt64
    let connectTimeoutMs: UInt64

    init(
        offer: RelayStreamOfferContract,
        credential: GuestCredential,
        guestIdentity: any ClawShareGuestIdentity,
        client: RelayStreamGuestDataPlaneClient = RelayStreamGuestDataPlaneClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() },
        ttlSecs: UInt64 = 60,
        connectTimeoutMs: UInt64 = 10_000
    ) {
        self.offer = offer
        self.credential = credential
        self.guestIdentity = guestIdentity
        self.client = client
        self.now = now
        self.uuid = uuid
        self.ttlSecs = ttlSecs
        self.connectTimeoutMs = connectTimeoutMs
    }

    func openClawSiteStream() async throws -> any ClawSiteStreamSession {
        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        // Re-verified on every dial, not just once when the claw was opened: an
        // offer that has since expired must stop working mid-session rather
        // than keep serving because the first request happened to succeed.
        try offer.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: nowUnix,
            allowedResources: [.clawSite]
        )

        let session = try await client.connect(
            offerCbor: offer.canonicalBytes(),
            credentialCbor: ClawShareCodec.encode(credential),
            expectedOwnerPub: credential.ownerPublicKey,
            expectedGuestPub: guestIdentity.publicKeyData,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: "ios-clawsite-\(uuid().uuidString.lowercased())",
            signer: ClawSiteSessionSigner(identity: guestIdentity),
            connectTimeoutMs: connectTimeoutMs
        )
        return ClawSiteRelayStreamSession(session: session)
    }
}

private struct ClawSiteSessionSigner: RelayStreamGuestSigning {
    let identity: any ClawShareGuestIdentity

    func signRelayStreamAuth(_ bytes: Data) async throws -> Data {
        try identity.sign(bytes)
    }
}
