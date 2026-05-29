import Foundation

/// Production `ClawShareSessionTokenSigning` backed by a guest device
/// identity — in the real app the Secure-Enclave key
/// (`SecureEnclaveClawShareGuestIdentity`), so the proof-of-possession token
/// is signed by hardware the extension can't reach. This is the last wire
/// between `ClawShareOpenCoordinator` and the existing
/// `ClawShareSessionTokenSigner` canonical-CBOR signer; it binds exactly
/// `(session_id, credential_hash, endpoint, target_id, nonce, expires_at)`.
public struct ClawShareGuestIdentitySigner: ClawShareSessionTokenSigning {
    private let guestIdentity: any ClawShareGuestIdentity

    public init(guestIdentity: any ClawShareGuestIdentity) {
        self.guestIdentity = guestIdentity
    }

    public func signedToken(
        sessionId: String,
        credentialCBOR: Data,
        endpoint: String,
        targetId: String,
        nonce: Data,
        expiresAtUnix: UInt64
    ) throws -> Data {
        try ClawShareSessionTokenSigner.signedTokenCBOR(
            sessionId: sessionId,
            credentialCBOR: credentialCBOR,
            endpoint: endpoint,
            targetId: targetId,
            nonce: nonce,
            expiresAtUnix: expiresAtUnix,
            guestIdentity: guestIdentity
        )
    }
}
