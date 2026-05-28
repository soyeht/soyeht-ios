import Foundation

/// Claw-share wire contract — the minimum shape iOS will exchange with the
/// theyos engine to claim time-bound guest access to a single claw.
///
/// These types mirror `household_rs::claw_share::{ClawShareInvite,
/// ClawShareClaim, GuestCredential, ClawShareAck, TunnelHandle}` field-for-field
/// so that canonical CBOR produced by either side round-trips.
///
/// **Scope of this file:** types only. No CBOR encoder, no signing, no NEX
/// integration — those land once the contract is stable on both sides and
/// the host-side e2e test demonstrates the full moment.
///
/// **Why a separate file from `JoinRequestEnvelope.swift`:** the existing
/// pair-machine flow joins a *Mac* to a household as a *member*. Claw-share
/// is a different ceremony — a household owner granting a *non-member* guest
/// access to a single claw — and the wire envelope is intentionally distinct
/// so neither flow's evolution drags the other.

// MARK: - TunnelHandle

/// How the guest's device should dial the data plane after the claim
/// succeeds. Transport-agnostic so the slice runs over loopback today and
/// over FIPS / Nostr mesh tomorrow without changing the wire envelope.
public enum ClawShareTunnelHandle: Sendable, Equatable {
    /// In-process channel keyed by an opaque string. Used by tests and
    /// the host-side single-machine harness during development.
    case loopback(channel: String)

    /// FIPS mesh endpoint. `peerNpub` identifies the engine peer; `hint`
    /// carries optional transport metadata (relay hint, direct-addr probe).
    case fips(peerNpub: String, hint: String?)
}

// MARK: - Invite

/// Envelope the owner shares with the guest out-of-band (link / QR /
/// AirDrop). Signed by the owner's P-256 household identity over the
/// canonical CBOR of every field except `ownerSignature`.
public struct ClawShareInvite: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind: String = "claw-share/invite"

    public let v: UInt8
    public let kind: String
    public let householdId: String
    public let ownerPersonId: String
    /// 33-byte SEC1-compressed P-256 public key.
    public let ownerPublicKey: Data
    public let clawId: String
    /// 16 bytes — CSPRNG, opaque on this side.
    public let slotId: Data
    public let transportHint: ClawShareTunnelHandle
    /// Unix seconds.
    public let expiresAt: UInt64
    /// Engine's Nostr identity (`npub1…`) the friend can publish the
    /// encrypted `ClawShareClaim` to over a relay. Carried on the
    /// invite (signed) so an offline engine can still consume the
    /// claim via store-and-forward once it comes back online.
    public let ownerEngineNpub: String
    /// Ordered list of Nostr relay WSS URLs the friend should publish
    /// the claim to. Owner picks these — first relay is the preferred
    /// path; iOS multi-relay failover walks the list.
    public let claimRelays: [String]
    /// 64-byte raw `r || s` ECDSA P-256.
    public let ownerSignature: Data

    public init(
        v: UInt8 = ClawShareInvite.currentVersion,
        kind: String = ClawShareInvite.kind,
        householdId: String,
        ownerPersonId: String,
        ownerPublicKey: Data,
        clawId: String,
        slotId: Data,
        transportHint: ClawShareTunnelHandle,
        expiresAt: UInt64,
        ownerEngineNpub: String,
        claimRelays: [String],
        ownerSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.householdId = householdId
        self.ownerPersonId = ownerPersonId
        self.ownerPublicKey = ownerPublicKey
        self.clawId = clawId
        self.slotId = slotId
        self.transportHint = transportHint
        self.expiresAt = expiresAt
        self.ownerEngineNpub = ownerEngineNpub
        self.claimRelays = claimRelays
        self.ownerSignature = ownerSignature
    }
}

// MARK: - Claim

/// Guest's device → engine. Proves possession of the guest device key and
/// freshness of the request.
public struct ClawShareClaim: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind: String = "claw-share/claim"

    public let v: UInt8
    public let kind: String
    public let slotId: Data
    public let guestDevicePublicKey: Data
    /// 32 bytes — fresh per-claim CSPRNG.
    public let nonce: Data
    public let timestamp: UInt64
    public let guestSignature: Data

    public init(
        v: UInt8 = ClawShareClaim.currentVersion,
        kind: String = ClawShareClaim.kind,
        slotId: Data,
        guestDevicePublicKey: Data,
        nonce: Data,
        timestamp: UInt64,
        guestSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.slotId = slotId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.nonce = nonce
        self.timestamp = timestamp
        self.guestSignature = guestSignature
    }
}

// MARK: - GuestCredential

/// Authorization grant issued by the owner after a successful claim. Bound
/// to `(clawId, guestDevicePublicKey, expiresAt)`. **Not** a household
/// member cert — never carries household-management authority.
public struct GuestCredential: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind: String = "claw-share/guest-credential"

    public let v: UInt8
    public let kind: String
    public let householdId: String
    public let ownerPersonId: String
    public let ownerPublicKey: Data
    public let clawId: String
    public let guestDevicePublicKey: Data
    public let slotId: Data
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public let ownerSignature: Data

    public init(
        v: UInt8 = GuestCredential.currentVersion,
        kind: String = GuestCredential.kind,
        householdId: String,
        ownerPersonId: String,
        ownerPublicKey: Data,
        clawId: String,
        guestDevicePublicKey: Data,
        slotId: Data,
        issuedAt: UInt64,
        expiresAt: UInt64,
        ownerSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.householdId = householdId
        self.ownerPersonId = ownerPersonId
        self.ownerPublicKey = ownerPublicKey
        self.clawId = clawId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.slotId = slotId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.ownerSignature = ownerSignature
    }
}

// MARK: - Ack

/// Engine → guest after a successful claim.
public struct ClawShareAck: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public let v: UInt8
    public let credential: GuestCredential
    public let tunnel: ClawShareTunnelHandle

    public init(
        v: UInt8 = ClawShareAck.currentVersion,
        credential: GuestCredential,
        tunnel: ClawShareTunnelHandle
    ) {
        self.v = v
        self.credential = credential
        self.tunnel = tunnel
    }
}

// MARK: - Errors

/// Operator-facing error surface for the claw-share claim. Mirrors the
/// host-side `ClawShareError` enum; cases that can only arise on the host
/// (e.g. slot-store errors) are not present here because the iOS side
/// only sees them as a typed server-error envelope or a transport drop.
public enum ClawShareError: Error, Equatable, Sendable {
    case inviteMalformed
    case inviteExpired
    case inviteSignatureRejected
    case claimSignatureRejected
    case credentialExpired
    case credentialSignatureRejected
    case credentialIssuerMismatch
    case credentialClawMismatch
    case credentialGuestMismatch
    case credentialSlotMismatch
    case transportClosed
    case unexpectedFrame
    case serverRejected(code: String, message: String?)
    /// Honest gate: the iOS app cannot yet publish claim events to a
    /// Nostr relay (no vetted Swift NIP-44 + Schnorr stack ships in
    /// SoyehtCore). The production claim path emits this so the UI
    /// shows a truthful "this share method isn't supported on iPhone
    /// yet — ask the inviter to share through a paired Mac" message
    /// instead of pretending HTTP works in a cross-network scenario.
    case iosClaimRelayNotYetWired
}
