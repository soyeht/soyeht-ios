import Foundation
import RelayStreamGuestFFI
import SoyehtCore

protocol RelayStreamInviteOpening: Sendable {
    func open(invite: ClawShareInvite) async throws -> RelayStreamTerminalConfiguration
}

protocol RelayStreamSessionOpening: Sendable {
    func openSession(
        offerCbor: Data,
        credentialCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        signer: any RelayStreamGuestSigning,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamTerminalSession
}

struct RelayStreamGuestSessionOpener: RelayStreamSessionOpening {
    private let client: RelayStreamGuestDataPlaneClient

    init(client: RelayStreamGuestDataPlaneClient = RelayStreamGuestDataPlaneClient()) {
        self.client = client
    }

    func openSession(
        offerCbor: Data,
        credentialCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        signer: any RelayStreamGuestSigning,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamTerminalSession {
        let session = try await client.connect(
            offerCbor: offerCbor,
            credentialCbor: credentialCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: sessionId,
            signer: signer,
            connectTimeoutMs: connectTimeoutMs
        )
        return RelayStreamGuestDataPlaneTerminalSession(session: session)
    }
}

struct RelayStreamOpenController: RelayStreamInviteOpening, Sendable {
    enum OpenError: Error, LocalizedError, Equatable {
        case missingRelayStreamOffer

        var errorDescription: String? {
            switch self {
            case .missingRelayStreamOffer:
                return String(localized: "The invite did not include a relay stream offer.")
            }
        }
    }

    private let claimSubmitter: any ClawShareClaimSubmitter
    private let identityProvider: any ClawShareGuestIdentityProvider
    private let sessionOpener: any RelayStreamSessionOpening
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID
    private let ttlSecs: UInt64
    private let connectTimeoutMs: UInt64

    init(
        claimSubmitter: any ClawShareClaimSubmitter = NostrClawShareClaimSubmitter(),
        identityProvider: any ClawShareGuestIdentityProvider = SecureEnclaveClawShareGuestIdentityProvider(),
        sessionOpener: any RelayStreamSessionOpening = RelayStreamGuestSessionOpener(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() },
        ttlSecs: UInt64 = 60,
        connectTimeoutMs: UInt64 = 10_000
    ) {
        self.claimSubmitter = claimSubmitter
        self.identityProvider = identityProvider
        self.sessionOpener = sessionOpener
        self.now = now
        self.uuid = uuid
        self.ttlSecs = ttlSecs
        self.connectTimeoutMs = connectTimeoutMs
    }

    func open(invite: ClawShareInvite) async throws -> RelayStreamTerminalConfiguration {
        let claimed = try await claimSubmitter.submit(invite: invite, identityProvider: identityProvider)
        guard let offer = claimed.relayStreamOffer else {
            throw OpenError.missingRelayStreamOffer
        }

        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        let sessionId = "ios-relay-stream-\(uuid().uuidString.lowercased())"
        let session = try await sessionOpener.openSession(
            offerCbor: offer.canonicalBytes(),
            credentialCbor: ClawShareCodec.encode(claimed.credential),
            expectedOwnerPub: claimed.credential.ownerPublicKey,
            expectedGuestPub: claimed.guestPublicKeyData,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: sessionId,
            signer: RelayStreamClaimedSessionSigner(identity: claimed.guestIdentity),
            connectTimeoutMs: connectTimeoutMs
        )
        return RelayStreamTerminalConfiguration(title: invite.clawId, session: session)
    }
}

private struct RelayStreamClaimedSessionSigner: RelayStreamGuestSigning {
    let identity: any ClawShareGuestIdentity

    func signRelayStreamAuth(_ bytes: Data) async throws -> Data {
        try identity.sign(bytes)
    }
}
