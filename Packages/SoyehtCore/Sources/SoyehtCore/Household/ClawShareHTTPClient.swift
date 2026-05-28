import Foundation
import CryptoKit

/// Friend-side claw-share claim flow over HTTP. Mirrors the host-side
/// `household_rs::claw_share_flow::friend_perform_claim`.
///
/// The friend's device generates a **fresh** P-256 keypair for each share
/// — no Apple-ID, email, or long-lived identity is bound to the claim.
/// The engine sees only `(claw_id, guest_device_pub)`.
///
/// On success returns a `ClaimedSession` with the verified credential and
/// the tunnel handle to dial. On failure throws a typed `ClawShareError`.

// MARK: - Result

public struct ClaimedSession: Sendable {
    public let credential: GuestCredential
    public let tunnel: ClawShareTunnelHandle
    /// The guest identity the friend's app must retain for any signed
    /// follow-up requests inside the credential's lifetime. Either
    /// in-process (ephemeral) or Secure Enclave-backed depending on
    /// which `ClawShareGuestIdentityProvider` minted it.
    public let guestIdentity: any ClawShareGuestIdentity
    public var guestPublicKeyData: Data { guestIdentity.publicKeyData }
}

// MARK: - Errors specific to the client

extension ClawShareError {
    public static let unexpectedHTTPStatus = ClawShareError.transportClosed
}

// MARK: - HTTP client

public enum ClawShareHTTPClient {
    /// Perform the friend-side claim against the engine's claim endpoint.
    ///
    /// `engineBase` is the base URL of the household engine (e.g.
    /// `http://carlos.local:8091` or the Tailnet/mesh address the friend
    /// can reach). The endpoint path is appended internally.
    ///
    /// `now` is dependency-injected so tests can pin the wall clock; the
    /// production caller passes `Date()`.
    public static func performClaim(
        invite: ClawShareInvite,
        engineBase: URL,
        session: URLSession = .shared,
        identityProvider: any ClawShareGuestIdentityProvider =
            EphemeralClawShareGuestIdentityProvider(),
        now: @autoclosure @Sendable () -> Date = Date()
    ) async throws -> ClaimedSession {
        // 1. Defense-in-depth: refuse expired invites client-side before
        //    spending a network round-trip.
        let nowUnix = UInt64(now().timeIntervalSince1970)
        if invite.expiresAt <= nowUnix {
            throw ClawShareError.inviteExpired
        }

        // 2. Fresh per-share device key from the injected provider.
        //    Default is the ephemeral in-process P256 key; production
        //    injects the Secure Enclave-backed provider.
        let guestIdentity: any ClawShareGuestIdentity
        do {
            guestIdentity = try identityProvider.create()
        } catch {
            throw ClawShareError.inviteMalformed
        }
        let guestPublicKeyData = guestIdentity.publicKeyData
        guard guestPublicKeyData.count == 33 else {
            throw ClawShareError.inviteMalformed
        }

        // 3. Build the canonical signing bytes (claim envelope minus
        //    `guest_signature`) and sign through the identity.
        let nonce = randomBytes(count: 32)
        let timestamp = UInt64(now().timeIntervalSince1970)
        let signingBytes = canonicalClaimSigningBytes(
            slotId: invite.slotId,
            guestDevicePublicKey: guestPublicKeyData,
            nonce: nonce,
            timestamp: timestamp
        )
        let signatureBytes: Data
        do {
            signatureBytes = try guestIdentity.sign(signingBytes)
        } catch {
            throw ClawShareError.claimSignatureRejected
        }
        guard signatureBytes.count == 64 else {
            throw ClawShareError.inviteMalformed
        }

        // 4. Compose the claim envelope and encode.
        let claim = ClawShareClaim(
            slotId: invite.slotId,
            guestDevicePublicKey: guestPublicKeyData,
            nonce: nonce,
            timestamp: timestamp,
            guestSignature: signatureBytes
        )
        let body = ClawShareCodec.encode(claim)

        // 5. POST to the engine.
        let endpoint = engineBase.appending(path: "/api/v1/claw-share/claim")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.setValue("application/cbor", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClawShareError.transportClosed
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClawShareError.transportClosed
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 410:
            throw ClawShareError.inviteExpired
        case 401:
            throw ClawShareError.claimSignatureRejected
        case 400, 404:
            throw try decodeServerError(data)
        case 503:
            throw ClawShareError.transportClosed
        default:
            throw try decodeServerError(data)
        }

        // 6. Decode + verify the ack.
        let ack: ClawShareAck
        do {
            ack = try ClawShareCodec.decodeAck(data)
        } catch {
            throw ClawShareError.unexpectedFrame
        }

        // 7. Verify credential signature under the invite's owner pubkey.
        //    Production will also walk the chain (owner → machine cert);
        //    the slice stops at "credential is signed by the same key
        //    that signed the invite", which is enough to detect a MITM
        //    on the loopback.
        try verifyCredentialSignature(ack.credential, expectedOwnerPub: invite.ownerPublicKey)

        // 8. Verify bindings.
        if ack.credential.ownerPublicKey != invite.ownerPublicKey {
            throw ClawShareError.credentialIssuerMismatch
        }
        if ack.credential.clawId != invite.clawId {
            throw ClawShareError.credentialClawMismatch
        }
        if ack.credential.guestDevicePublicKey != guestPublicKeyData {
            throw ClawShareError.credentialGuestMismatch
        }
        if ack.credential.slotId != invite.slotId {
            throw ClawShareError.credentialSlotMismatch
        }
        if ack.credential.expiresAt <= UInt64(now().timeIntervalSince1970) {
            throw ClawShareError.credentialExpired
        }

        return ClaimedSession(
            credential: ack.credential,
            tunnel: ack.tunnel,
            guestIdentity: guestIdentity
        )
    }

    // MARK: - Helpers

    static func canonicalClaimSigningBytes(
        slotId: Data,
        guestDevicePublicKey: Data,
        nonce: Data,
        timestamp: UInt64
    ) -> Data {
        // Mirrors the Rust `ClawShareClaimUnsigned` field set — same keys,
        // canonical sort order applied by HouseholdCBOR.encode.
        HouseholdCBOR.encode(.map([
            "guest_device_pub": .bytes(guestDevicePublicKey),
            "kind": .text("claw-share/claim"),
            "nonce": .bytes(nonce),
            "slot_id": .bytes(slotId),
            "timestamp": .unsigned(timestamp),
            "v": .unsigned(1),
        ]))
    }

    fileprivate static func canonicalCredentialSigningBytes(_ c: GuestCredential) -> Data {
        // Mirrors `GuestCredentialUnsigned` — all fields except `owner_signature`.
        HouseholdCBOR.encode(.map([
            "claw_id": .text(c.clawId),
            "expires_at": .unsigned(c.expiresAt),
            "guest_device_pub": .bytes(c.guestDevicePublicKey),
            "hh_id": .text(c.householdId),
            "issued_at": .unsigned(c.issuedAt),
            "kind": .text(c.kind),
            "owner_p_id": .text(c.ownerPersonId),
            "owner_p_pub": .bytes(c.ownerPublicKey),
            "slot_id": .bytes(c.slotId),
            "v": .unsigned(UInt64(c.v)),
        ]))
    }

    fileprivate static func verifyCredentialSignature(
        _ credential: GuestCredential,
        expectedOwnerPub: Data
    ) throws {
        guard credential.ownerPublicKey == expectedOwnerPub else {
            throw ClawShareError.credentialIssuerMismatch
        }
        let pubKey: P256.Signing.PublicKey
        do {
            pubKey = try P256.Signing.PublicKey(compressedRepresentation: credential.ownerPublicKey)
        } catch {
            throw ClawShareError.credentialSignatureRejected
        }
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: credential.ownerSignature)
        } catch {
            throw ClawShareError.credentialSignatureRejected
        }
        let signingBytes = canonicalCredentialSigningBytes(credential)
        guard pubKey.isValidSignature(signature, for: signingBytes) else {
            throw ClawShareError.credentialSignatureRejected
        }
    }

    fileprivate static func decodeServerError(_ data: Data) throws -> ClawShareError {
        guard case .map(let map) = (try? HouseholdCBOR.decode(data)) else {
            return ClawShareError.transportClosed
        }
        let code: String
        if case .text(let c) = map["code"] {
            code = c
        } else {
            return ClawShareError.transportClosed
        }
        let message: String?
        if case .text(let m) = map["message"] {
            message = m
        } else {
            message = nil
        }
        return ClawShareError.serverRejected(code: code, message: message)
    }

    fileprivate static func randomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return bytes
    }
}
