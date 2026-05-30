import Foundation

/// Builds the host-signed proof-of-possession token the extension hands
/// to the engine. The token binds `(session_id, credential_hash,
/// endpoint, target_id, nonce, expires_at)` and is signed by the guest
/// device key — so a stolen credential blob alone cannot open a session,
/// a token can't be replayed (single-use nonce), and it can't be used
/// against a different target.
///
/// The host app produces this (it can reach the Secure-Enclave guest
/// key; the extension can't), stages it in the App Group, and the
/// extension forwards it. The CBOR layout MUST match the Rust
/// `household_rs::claw_share_data_tunnel::SessionAuthToken`: the signature
/// covers the canonical CBOR of the unsigned body
/// `{session_id, credential_hash, endpoint, target_id, nonce, expires_at}`
/// (canonical key order is enforced by `HouseholdCBOR`). Pinned by
/// `ClawShareSessionTokenCrossLanguageTests`.
public enum ClawShareSessionTokenSigner {
    /// Max TTL the engine accepts (mirror of the Rust constant).
    public static let maxTTLSeconds: UInt64 = 300

    /// Canonical CBOR of the unsigned token body — the bytes that are
    /// signed and that the engine re-derives to verify.
    public static func unsignedBody(
        sessionId: String,
        credentialCBOR: Data,
        endpoint: String,
        targetId: String,
        nonce: Data,
        expiresAtUnix: UInt64
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "session_id": .text(sessionId),
            "credential_hash": .bytes(HouseholdHash.blake3(credentialCBOR)),
            "endpoint": .text(endpoint),
            "target_id": .text(targetId),
            "nonce": .bytes(nonce),
            "expires_at": .unsigned(expiresAtUnix),
        ]))
    }

    /// Sign the token with the guest device key and return its canonical
    /// CBOR (ready to stage for the extension).
    public static func signedTokenCBOR(
        sessionId: String,
        credentialCBOR: Data,
        endpoint: String,
        targetId: String,
        nonce: Data,
        expiresAtUnix: UInt64,
        guestIdentity: any ClawShareGuestIdentity
    ) throws -> Data {
        let credentialHash = HouseholdHash.blake3(credentialCBOR)
        let body = unsignedBody(
            sessionId: sessionId,
            credentialCBOR: credentialCBOR,
            endpoint: endpoint,
            targetId: targetId,
            nonce: nonce,
            expiresAtUnix: expiresAtUnix
        )
        let signature = try guestIdentity.sign(body) // SHA256 + raw P256 (matches Rust)
        return HouseholdCBOR.encode(.map([
            "session_id": .text(sessionId),
            "credential_hash": .bytes(credentialHash),
            "endpoint": .text(endpoint),
            "target_id": .text(targetId),
            "nonce": .bytes(nonce),
            "expires_at": .unsigned(expiresAtUnix),
            "signature": .bytes(signature),
        ]))
    }
}
