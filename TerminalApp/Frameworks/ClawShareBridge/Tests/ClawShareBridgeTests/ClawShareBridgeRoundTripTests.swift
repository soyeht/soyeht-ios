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

    private func credentialBytes() -> Data {
        Data(hexString: Self.signedCredentialHex)
    }

    /// load → start → health → `.connected`, gate honoured at every step.
    func testStartThenHealthReachesConnectedOverLoopback() async throws {
        let port = try await startLoopbackEchoServer()
        let session = ClawSession()

        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)

        let outcome = try await session.startSession(
            config: DataPlaneConfig(host: "127.0.0.1", port: port)
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

    /// The full Round-15 gate over the real loopback tunnel:
    /// start → health (Connected = tunnel ready) → verifyPacketPath
    /// (PacketVerified = real packet RTT) → steady-state send/receive.
    func testPacketRoundTripReachesPacketVerified() async throws {
        let port = try await startLoopbackEchoServer()
        let session = ClawSession()
        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)
        _ = try await session.startSession(config: DataPlaneConfig(host: "127.0.0.1", port: port))

        // Health → Connected (tunnel ready, NOT yet packet-verified).
        let health = try await session.healthPing()
        guard case .connected = health else { return XCTFail("health → Connected, got \(health)") }

        // Real packet round-trip → PacketVerified.
        let verified = try await session.verifyPacketPath()
        guard case .packetVerified = verified else {
            return XCTFail("packet RTT → PacketVerified, got \(verified)")
        }

        // Steady-state pump primitive: a packet sent comes back.
        let payload = Data([0x60, 0x00, 0x00, 0x00, 0x11, 0x22])
        try await session.sendPacket(packet: payload)
        let echo = try await session.receivePacket()
        XCTAssertEqual(echo, payload, "packet must round-trip through the real tunnel")
    }

    /// Endpoint down: `startSession` fails typed and the session never
    /// becomes connected. No crash.
    func testStartFailsWhenEndpointDown() async throws {
        let session = ClawSession()
        _ = try await session.loadCredential(credentialCbor: credentialBytes(), nowUnix: Self.validNowUnix)
        do {
            // Port 1 is not listening — connect must fail.
            _ = try await session.startSession(config: DataPlaneConfig(host: "127.0.0.1", port: 1))
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
