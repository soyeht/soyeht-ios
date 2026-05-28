import XCTest
@testable import ClawShareBridge

/// End-to-end transport test against the REAL Rust bridge: the Swift
/// layer drives `loadCredential` → `startSession` → `healthPing` through
/// the framework, against an in-process echo server that runs the real
/// `serve_connection` loop (`startLoopbackEchoServer`). This proves the
/// round's headline claim — Swift can start a session + health ping over
/// the framework and only reaches `.connected` after a real packet
/// round-trip.
///
/// The credential is a fully-signed `GuestCredential` (canonical CBOR
/// produced by the Rust `fake_credential()` helper). `loadCredential`
/// verifies the owner signature in Rust, so an unsigned fixture would be
/// rejected — this byte string is the real thing.
final class ClawShareBridgeRoundTripTests: XCTestCase {
    /// Owner [0x11;32] / guest [0x33;32], claw_test, expires 1_800_086_400.
    private static let signedCredentialHex =
        "ab617601646b696e64781b636c61772d73686172652f67756573742d63726564656e7469616c65"
        + "68685f6964783768685f6a707173797570796f747268676175343579376e6575336c3370346c"
        + "65723678687537646e32783232337232716636616769727167636c61775f696469636c61775f"
        + "7465737467736c6f745f69645022222222222222222222222222222222696973737565645f61"
        + "741a6b49d2006a657870697265735f61741a6b4b23806a6f776e65725f705f69647836705f6a"
        + "707173797570796f747268676175343579376e6575336c3370346c65723678687537646e3278"
        + "323233723271663661676972716b6f776e65725f705f7075625821020217e617f0b644392827"
        + "8f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed6f6f776e65725f7369676e6174757265"
        + "5840af6d0f9a39cee355bf4708f55d050c9f29dae1ea47a063ae1a9a0f9c7b531650669984e03"
        + "3b2148f8db6446466672785741da6fcddc33cb5d9651cf09d3a47287067756573745f64657669"
        + "63655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f"
        + "25e7d"

    private static let validNowUnix: UInt64 = 1_800_000_001

    /// A valid `SessionAuthToken` CBOR (signed by the guest device key).
    /// The loopback server skips token verification, so any decodable
    /// token works here — the engine-side PoP verification matrix is
    /// covered by the Rust tests.
    private static let sessionTokenHex =
        "a7656e6f6e6365416e68656e64706f696e746165697369676e61747572655840cbd1298de1908d0d"
        + "ea2ab669dd4469c01f1e4fb24bcce2ab8a3b6c16afad35e7d06c9f43ee8d62ac0df9083381ca740"
        + "068449f39ecb5237fd793976d31d4c850697461726765745f696469636c61775f746573746a6578"
        + "70697265735f61741a6b49d23c6a73657373696f6e5f696461736f63726564656e7469616c5f6861"
        + "736858203ae7d805f6789a6402acb70ad4096a85a56bf6804eaf25c0493ac697548d30b5"

    private func credentialBytes() -> Data {
        Data(hexString: Self.signedCredentialHex)
    }

    private func sessionToken() -> Data {
        Data(hexString: Self.sessionTokenHex)
    }

    /// load → start → health → `.connected`, gate honoured at every step.
    func testStartThenHealthReachesConnectedOverLoopback() async throws {
        let port = try await startLoopbackEchoServer()
        let session = ClawSession()

        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)

        let outcome = try await session.startSession(
            config: DataPlaneConfig(host: "127.0.0.1", port: port),
            sessionTokenCbor: sessionToken()
        )
        // Gate: never connected straight after start.
        if case .connected = outcome.status {
            return XCTFail("startSession must not report .connected before a health round-trip")
        }
        XCTAssertFalse(outcome.meshIpv6.isEmpty, "engine ack should carry a mesh address")

        let final = try await session.healthPing()
        guard case .connected = final else {
            return XCTFail("only a real health round-trip may reach .connected, got \(final)")
        }
    }

    /// The full Round-18 gate over the real loopback tunnel:
    /// start → health (Connected = tunnel ready) → openStream — which only
    /// reaches InteractiveReady AFTER the target's first output (the
    /// banner). Then resize the terminal and round-trip multiple data
    /// frames on the SAME interactive session.
    func testOpenStreamReachesInteractiveReadyAfterFirstOutput() async throws {
        let port = try await startLoopbackEchoServer()
        let session = ClawSession()
        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)
        _ = try await session.startSession(
            config: DataPlaneConfig(host: "127.0.0.1", port: port),
            sessionTokenCbor: sessionToken()
        )

        // Health → Connected (tunnel ready, NOT yet openable).
        let health = try await session.healthPing()
        guard case .connected = health else { return XCTFail("health → Connected, got \(health)") }

        // Open → InteractiveReady (only after the target's first output).
        let ready = try await session.openStream()
        guard case .interactiveReady = ready else {
            return XCTFail("open → InteractiveReady, got \(ready)")
        }

        // The first output (the banner that flipped InteractiveReady) is
        // returned first; resize is accepted; data round-trips on the SAME
        // interactive session.
        let banner = try await session.receiveData()
        XCTAssertEqual(banner, Data("FAKE-SSH-BANNER".utf8))
        try await session.resize(cols: 120, rows: 40)
        for line in ["ls\n", "pwd\n"] {
            try await session.sendData(data: Data(line.utf8))
            let ack = try await session.receiveData()
            XCTAssertEqual(ack, Data("ACK:\(line)".utf8))
        }
    }

    /// Endpoint down: `startSession` fails typed and the session never
    /// becomes connected. No crash.
    func testStartFailsWhenEndpointDown() async throws {
        let session = ClawSession()
        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)
        do {
            // Port 1 is not listening — connect must fail.
            _ = try await session.startSession(config: DataPlaneConfig(host: "127.0.0.1", port: 1), sessionTokenCbor: sessionToken())
            XCTFail("startSession against a dead endpoint must throw")
        } catch is BridgeError {
            // expected (TransportFailed / HandshakeFailed)
        }
        if case .connected = await session.status() {
            XCTFail("a failed dial must never leave the session connected")
        }
    }

    /// health ping before start has no session → typed error, no crash.
    func testHealthPingBeforeStartThrows() async throws {
        let session = ClawSession()
        do {
            _ = try await session.healthPing()
            XCTFail("healthPing without a session must throw")
        } catch is BridgeError {
            // expected (NoSession)
        }
    }
}

private extension Data {
    init(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            data.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
