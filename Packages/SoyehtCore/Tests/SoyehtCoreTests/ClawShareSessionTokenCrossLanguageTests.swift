import Foundation
import XCTest

@testable import SoyehtCore

/// Pins the Swift session-token CBOR to the Rust
/// `household_rs::claw_share_data_tunnel::SessionAuthTokenUnsigned`
/// canonical encoding. The engine verifies the host's signature over
/// exactly these bytes, so any drift would silently break every real
/// session — this test fails first instead.
///
/// The hex is produced by the Rust side for the same inputs
/// (`session_id="sess-x"`, `credential = "credbytes"`,
/// `endpoint="claw:7423"`, `expires_at=1_800_000_060`).
final class ClawShareSessionTokenCrossLanguageTests: XCTestCase {
    func testUnsignedTokenBodyMatchesRustCanonicalCBOR() {
        let body = ClawShareSessionTokenSigner.unsignedBody(
            sessionId: "sess-x",
            credentialCBOR: Data("credbytes".utf8),
            endpoint: "claw:7423",
            expiresAtUnix: 1_800_000_060
        )
        let expected =
            "a468656e64706f696e7469636c61773a373432336a657870697265735f61741a6b49d23c"
            + "6a73657373696f6e5f696466736573732d786f63726564656e7469616c5f686173685820"
            + "c3afb4c2a37d97ee82cd823c6c8db8543dce9708dae5600c9df842a2c982b793"
        XCTAssertEqual(
            body.map { String(format: "%02x", $0) }.joined(),
            expected,
            "Swift session-token CBOR drifted from the Rust SessionAuthTokenUnsigned fixture"
        )
    }
}
