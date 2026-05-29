import Foundation

/// Result of a successful owner-side claw-share mint.
public struct ClawShareMintResult: Sendable, Equatable {
    /// `soyeht://claw-share/v1?e=…` — the shareable invite link. Carries the
    /// signed `ClawShareInvite` the guest's device redeems; consumable by the
    /// friend path (`ClawShareInviteCenter.handleDeepLink`) and `friend-cli`.
    public let uri: String
    /// Opaque 16-byte slot id, kept so the owner can later revoke this share
    /// (`POST /api/v1/claw-share/revoke`). Never share an invite you can't revoke.
    public let slotId: Data
    /// Unix seconds the invite — and the credential it yields — expire.
    public let expiresAt: UInt64

    public init(uri: String, slotId: Data, expiresAt: UInt64) {
        self.uri = uri
        self.slotId = slotId
        self.expiresAt = expiresAt
    }
}

/// Typed failures lifted from the mint endpoint's CBOR response. Transport /
/// auth failures surface as the underlying `SoyehtAPIClient` errors
/// (`HouseholdPoPError`, `APIError`) so the UI can tell "you don't have
/// permission" apart from "the engine rejected the request".
public enum ClawShareMintError: Error, Equatable {
    case responseMalformed
    case versionUnsupported(UInt64)
}

/// Owner-side claw-share invite minter.
///
/// Mints a time-bound invite by calling the **real, PoP-authenticated** engine
/// endpoint `POST /api/v1/claw-share/invites` through the app's existing
/// household request transport (`SoyehtAPIClient.householdRequest`). The owner's
/// device signs the request with its enrolled Secure-Enclave identity — exactly
/// as it does for every other household-authority operation (`household.invite`
/// caveat). No new key, no new auth surface, no parallel helper, no bypass: if
/// the device can't produce a valid owner PoP, the mint fails.
public struct ClawShareComposer {
    /// Engine route that mints the invite (owner; PoP-authed).
    public static let mintPath = "/api/v1/claw-share/invites"
    /// Engine route that revokes a slot (owner; PoP-authed).
    public static let revokePath = "/api/v1/claw-share/revoke"
    /// Caveat the owner cert must carry to mint (mirrors `Operation::HouseholdInvite`).
    public static let inviteOperation = "household.invite"
    /// Caveat the owner cert must carry to revoke (mirrors `Operation::HouseholdRevoke`).
    public static let revokeOperation = "household.revoke"
    /// Canonical CBOR is the wire format on both sides.
    public static let contentType = "application/cbor"

    private let apiClient: SoyehtAPIClient

    public init(apiClient: SoyehtAPIClient) {
        self.apiClient = apiClient
    }

    /// Mint a time-bound invite to share `clawId` with one guest.
    ///
    /// - Parameters:
    ///   - clawId: the claw/host being shared (e.g. the Mac host's instance id).
    ///   - ttlSeconds: how long the invite stays valid; the engine clamps it to
    ///     its own `MAX_INVITE_TTL_SECS`.
    ///   - endpoint: the Mac/server hosting the claw. `nil` targets the active
    ///     household endpoint.
    /// - Returns: the shareable URI + slot id (for revocation) + expiry.
    /// - Throws: `HouseholdPoPError`/`APIError` on auth or transport failure
    ///   (the device couldn't sign a valid owner PoP, or the engine rejected
    ///   it), or `ClawShareMintError` on a malformed/unsupported response.
    public func mintInvite(
        clawId: String,
        ttlSeconds: UInt64 = 3600,
        endpoint: URL? = nil
    ) async throws -> ClawShareMintResult {
        let body = HouseholdCBOR.encode(.map([
            "claw_id": .text(clawId),
            "ttl_secs": .unsigned(ttlSeconds),
            "v": .unsigned(UInt64(ClawShareInvite.currentVersion)),
        ]))

        let (data, _) = try await apiClient.householdRequest(
            endpoint: endpoint,
            path: Self.mintPath,
            method: "POST",
            body: body,
            requiredOperation: Self.inviteOperation,
            additionalHeaders: ["Content-Type": Self.contentType]
        )

        return try Self.decodeResponse(data)
    }

    /// Revoke a previously minted share by its slot id. Authenticated by the
    /// owner's `household.revoke` authority — the same PoP path as mint. Tearing
    /// down access must always be possible: never share an invite you can't revoke.
    ///
    /// - Parameters:
    ///   - slotId: the 16-byte slot id from a `ClawShareMintResult`.
    ///   - endpoint: the Mac/server hosting the claw (`nil` → active household).
    public func revokeInvite(slotId: Data, endpoint: URL? = nil) async throws {
        let body = HouseholdCBOR.encode(.map([
            "slot_id": .bytes(slotId),
            "v": .unsigned(UInt64(ClawShareInvite.currentVersion)),
        ]))
        _ = try await apiClient.householdRequest(
            endpoint: endpoint,
            path: Self.revokePath,
            method: "POST",
            body: body,
            requiredOperation: Self.revokeOperation,
            additionalHeaders: ["Content-Type": Self.contentType]
        )
    }

    /// Decode the engine's canonical-CBOR `MintInviteResponse`
    /// (`{v, uri, slot_id, expires_at}`). Internal for unit coverage.
    static func decodeResponse(_ data: Data) throws -> ClawShareMintResult {
        guard case let .map(map) = try HouseholdCBOR.decode(data) else {
            throw ClawShareMintError.responseMalformed
        }
        guard case let .unsigned(version)? = map["v"] else {
            throw ClawShareMintError.responseMalformed
        }
        guard version == UInt64(ClawShareInvite.currentVersion) else {
            throw ClawShareMintError.versionUnsupported(version)
        }
        guard
            case let .text(uri)? = map["uri"],
            case let .bytes(slotId)? = map["slot_id"],
            case let .unsigned(expiresAt)? = map["expires_at"]
        else {
            throw ClawShareMintError.responseMalformed
        }
        return ClawShareMintResult(uri: uri, slotId: slotId, expiresAt: expiresAt)
    }
}
