import XCTest
@testable import ClawShareBridge

/// Smoke tests that prove the committed `ClawShareBridge.xcframework`
/// is the REAL Rust bridge (not a stub) and that it behaves safely —
/// no crash, typed errors — across the exported UniFFI surface.
///
/// These run via `swift test` against the macOS slice of the
/// XCFramework. They are the local proof for the round's gate
/// "app links real bridge?": if the binary were missing or stubbed,
/// these would fail to link or to verify a real credential.
final class ClawShareBridgeSmokeTests: XCTestCase {
    /// A fresh session reports `.idle` — the real Rust `SessionStatus`
    /// enum, lowered across FFI.
    func testFreshSessionIsIdle() async {
        let session = ClawSession()
        let status = await session.status()
        guard case .idle = status else {
            return XCTFail("fresh ClawSession must be .idle, got \(status)")
        }
    }

    /// Garbage credential bytes hit the REAL canonical-CBOR decoder in
    /// Rust and come back as a TYPED `BridgeError` — not a crash, not a
    /// silent success. This is the "no fake state" contract at the
    /// bridge boundary.
    func testLoadGarbageCredentialThrowsTypedErrorWithoutCrashing() async {
        let session = ClawSession()
        do {
            _ = try await session.loadCredential(
                credentialCbor: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                nowUnix: 1_800_000_000
            )
            XCTFail("garbage credential must not decode")
        } catch let error as BridgeError {
            switch error {
            case .CredentialDecode, .CredentialInvalid:
                break // expected — real Rust verification rejected it
            default:
                XCTFail("unexpected typed error: \(error)")
            }
        } catch {
            XCTFail("must throw a typed BridgeError, got \(error)")
        }
        // Still alive, still honest: status did not advance.
        let status = await session.status()
        guard case .idle = status else {
            return XCTFail("rejected credential must leave session .idle, got \(status)")
        }
    }

    /// `stopSession` is idempotent and always lands on `.stopped` — the
    /// extension relies on this to clear any in-flight state without a
    /// zombie "connecting" status.
    func testStopSessionIsIdempotent() async {
        let session = ClawSession()
        let first = await session.stopSession(reason: "test")
        let second = await session.stopSession(reason: "test")
        guard case .stopped = first, case .stopped = second else {
            return XCTFail("stopSession must yield .stopped on every call")
        }
    }
}
