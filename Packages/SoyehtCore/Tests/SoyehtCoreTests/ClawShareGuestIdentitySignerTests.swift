import Foundation
import XCTest

@testable import SoyehtCore

/// The production token signer wires `ClawShareOpenCoordinator` to the
/// canonical-CBOR `ClawShareSessionTokenSigner` using a guest identity (SE in
/// the app). Byte-exact correctness of the signed body is pinned by
/// `ClawShareSessionTokenCrossLanguageTests`; here we verify the adapter
/// delegates and produces a stable token for fixed inputs.
final class ClawShareGuestIdentitySignerTests: XCTestCase {
    /// Deterministic stand-in for the SE identity (fixed sig + pubkey).
    private struct FakeIdentity: ClawShareGuestIdentity {
        var publicKeyData: Data { Data(repeating: 0x03, count: 33) }
        func sign(_ data: Data) throws -> Data { Data(repeating: 0x07, count: 64) }
    }

    func testSignerProducesStableTokenForFixedInputs() throws {
        let signer = ClawShareGuestIdentitySigner(guestIdentity: FakeIdentity())
        let a = try signer.signedToken(
            sessionId: "sess-x",
            credentialCBOR: Data("credbytes".utf8),
            endpoint: "claw:7423",
            targetId: "claw-x",
            nonce: Data("nonce-x".utf8),
            expiresAtUnix: 1_800_000_060
        )
        let b = try signer.signedToken(
            sessionId: "sess-x",
            credentialCBOR: Data("credbytes".utf8),
            endpoint: "claw:7423",
            targetId: "claw-x",
            nonce: Data("nonce-x".utf8),
            expiresAtUnix: 1_800_000_060
        )
        XCTAssertFalse(a.isEmpty, "signer must produce a token")
        XCTAssertEqual(a, b, "same inputs + identity → identical token CBOR")
    }

    func testDifferentTargetProducesDifferentToken() throws {
        let signer = ClawShareGuestIdentitySigner(guestIdentity: FakeIdentity())
        let base = try signer.signedToken(
            sessionId: "s", credentialCBOR: Data("c".utf8), endpoint: "e",
            targetId: "claw-a", nonce: Data("n".utf8), expiresAtUnix: 1_800_000_060
        )
        let other = try signer.signedToken(
            sessionId: "s", credentialCBOR: Data("c".utf8), endpoint: "e",
            targetId: "claw-b", nonce: Data("n".utf8), expiresAtUnix: 1_800_000_060
        )
        XCTAssertNotEqual(base, other, "target_id is bound into the signed body")
    }
}
