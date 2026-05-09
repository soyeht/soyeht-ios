import Foundation

public enum JoinRequestTransportOrigin: String, Sendable, Equatable, CaseIterable {
    case bonjourShortcut = "bonjour-shortcut"
    case qrLAN = "qr-lan"
    case qrTailscale = "qr-tailscale"

    public init?(rawString: String) {
        self.init(rawValue: rawString)
    }

    public var wireValue: String {
        switch self {
        case .bonjourShortcut, .qrLAN:
            return PairMachineTransport.lan.rawValue
        case .qrTailscale:
            return PairMachineTransport.tailscale.rawValue
        }
    }
}

/// Unified in-memory join request the iPhone presents to the operator.
///
/// Both Story 1 (Bonjour-shortcut, decoded from `OwnerEvent.payload.join_request_cbor`)
/// and Story 2 (remote QR, parsed from a `pair-machine` URI) converge to this
/// type. `challengeSignature` is therefore present on every envelope —
/// FR-029 verification runs once on this single shape regardless of transport.
public struct JoinRequestEnvelope: Equatable, Sendable {
    public let householdId: String
    public let machinePublicKey: Data
    public let nonce: Data
    public let rawHostname: String
    public let rawPlatform: String
    public let candidateAddress: String
    public let ttlUnix: UInt64
    public let challengeSignature: Data
    public let transportOrigin: JoinRequestTransportOrigin
    public let receivedAt: Date
    /// 32-byte secret minted by the candidate at install time and carried in
    /// the QR. The iPhone replays it on `POST /pair-machine/local/anchor` to
    /// pin `(hh_id, hh_pub)` on the candidate before the founder Mac
    /// finalizes — closes B7 self-mint attack
    /// (`specs/003-machine-join/contracts/local-anchor.md`).
    ///
    /// Optional because the Bonjour-shortcut path
    /// (`OwnerEvent.payload.join_request_cbor`) does NOT carry an
    /// anchor secret today. Such envelopes cannot pin a trust anchor;
    /// `HouseholdMachineJoinRuntime.submitAction` skips the anchor POST and
    /// the candidate's `local/finalize` will reject the ceremony — that's
    /// the correct fail-closed behaviour until Bonjour-shortcut grows an
    /// equivalent secret carrier.
    public let anchorSecret: Data?

    public init(
        householdId: String,
        machinePublicKey: Data,
        nonce: Data,
        rawHostname: String,
        rawPlatform: String,
        candidateAddress: String,
        ttlUnix: UInt64,
        challengeSignature: Data,
        transportOrigin: JoinRequestTransportOrigin,
        receivedAt: Date,
        anchorSecret: Data? = nil
    ) {
        self.householdId = householdId
        self.machinePublicKey = machinePublicKey
        self.nonce = nonce
        self.rawHostname = rawHostname
        self.rawPlatform = rawPlatform
        self.candidateAddress = candidateAddress
        self.ttlUnix = ttlUnix
        self.challengeSignature = challengeSignature
        self.transportOrigin = transportOrigin
        self.receivedAt = receivedAt
        self.anchorSecret = anchorSecret
    }

    public init(
        from qr: PairMachineQR,
        householdId: String,
        receivedAt: Date
    ) {
        let transportOrigin: JoinRequestTransportOrigin = {
            switch qr.transport {
            case .lan: return .qrLAN
            case .tailscale: return .qrTailscale
            }
        }()
        self.init(
            householdId: householdId,
            machinePublicKey: qr.machinePublicKey,
            nonce: qr.nonce,
            rawHostname: qr.hostname,
            rawPlatform: qr.platform.rawValue,
            candidateAddress: qr.address,
            ttlUnix: UInt64(qr.expiresAt.timeIntervalSince1970),
            challengeSignature: qr.challengeSignature,
            transportOrigin: transportOrigin,
            receivedAt: receivedAt,
            anchorSecret: qr.anchorSecret
        )
    }

    public var idempotencyKey: String {
        "\(householdId)|\(machinePublicKey.soyehtBase64URLEncodedString())|\(nonce.soyehtBase64URLEncodedString())"
    }

    public func displayHostname(
        maxCharacters: Int = JoinRequestSafeRenderer.defaultMaxCharacters
    ) -> String {
        JoinRequestSafeRenderer.render(rawHostname, maxCharacters: maxCharacters)
    }

    public func displayPlatform(
        maxCharacters: Int = JoinRequestSafeRenderer.defaultMaxCharacters
    ) -> String {
        JoinRequestSafeRenderer.render(rawPlatform, maxCharacters: maxCharacters)
    }

    public func isExpired(now: Date) -> Bool {
        let expiry = Date(timeIntervalSince1970: TimeInterval(ttlUnix))
        return expiry <= now
    }
}
