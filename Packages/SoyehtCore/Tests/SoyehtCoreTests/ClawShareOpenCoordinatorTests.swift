import Foundation
import XCTest

@testable import SoyehtCore

/// Open-gate contract: the coordinator only becomes openable after a real
/// interactive session, refuses when a dependency is missing or the token
/// can't be signed, and never hands out a client unless openable. The fake
/// client lives ONLY in this test target.
final class ClawShareOpenCoordinatorTests: XCTestCase {
    private static let cred = Data("credbytes".utf8)
    private static let endpoint = ClawShareDataPlaneEndpoint(host: "192.168.15.13", port: 7423)
    private static let claw = "claw_test"
    private static func inputs() -> ClawShareOpenInputs {
        ClawShareOpenInputs(credentialCBOR: cred, endpoint: endpoint, targetClawId: claw)
    }

    /// Fake client whose openStream result is scriptable; records the token it
    /// was started with so we can assert it was signed + forwarded.
    private actor FakeClient: ClawShareDataPlaneClient {
        let openStatus: ClawShareSessionStatus
        private(set) var startedToken: Data?
        init(openStatus: ClawShareSessionStatus) { self.openStatus = openStatus }
        func loadCredential(_ c: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus { .credentialReady }
        func startSession(endpoint: ClawShareDataPlaneEndpoint, sessionToken: Data) async throws -> ClawShareStartOutcome {
            startedToken = sessionToken
            return ClawShareStartOutcome(meshIPv6: "fd00:c1aw::1", mtu: 1280, sessionId: "t", status: .awaitingFirstPacket)
        }
        func healthPing() async throws -> ClawShareSessionStatus { .connected(sinceUnix: 1) }
        func openStream() async throws -> ClawShareSessionStatus { openStatus }
        func sendData(_ packet: Data) async throws {}
        func receiveData() async throws -> Data { Data() }
        func resize(cols: UInt16, rows: UInt16) async throws {}
        func currentStatus() async -> ClawShareSessionStatus { openStatus }
        func stopSession(reason: String) async -> ClawShareSessionStatus { .stopped(reason: reason) }
        func token() -> Data? { startedToken }
    }

    private struct FakeFactory: ClawShareDataPlaneClientFactory {
        let client: FakeClient
        func makeClient() -> any ClawShareDataPlaneClient { client }
    }

    private struct StubSigner: ClawShareSessionTokenSigning {
        let result: Result<Data, Error>
        func signedToken(sessionId: String, credentialCBOR: Data, endpoint: String, targetId: String, nonce: Data, expiresAtUnix: UInt64) throws -> Data {
            try result.get()
        }
    }
    private struct SignerError: Error {}

    func testReachesOpenableOnInteractiveReady() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let coord = ClawShareOpenCoordinator(
            factory: FakeFactory(client: client),
            signer: StubSigner(result: .success(Data("token".utf8)))
        )
        let phase = await coord.bringUp(Self.inputs(), nowUnix: 1_800_000_000)
        guard case .openable = phase else { return XCTFail("must be openable, got \(phase)") }
        let canOpen = await coord.canOpen
        XCTAssertTrue(canOpen, "interactiveReady → Open shown")
        let started = await coord.startedClient()
        XCTAssertNotNil(started, "openable must hand out the live client")
        // The signed token was forwarded to startSession.
        let token = await client.token()
        XCTAssertEqual(token, Data("token".utf8))
    }

    func testMissingDependencyNeverOpens() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let coord = ClawShareOpenCoordinator(
            factory: FakeFactory(client: client),
            signer: StubSigner(result: .success(Data("token".utf8)))
        )
        // Empty credential → unavailable, no client constructed/started.
        let bad = ClawShareOpenInputs(credentialCBOR: Data(), endpoint: Self.endpoint, targetClawId: Self.claw)
        let phase = await coord.bringUp(bad, nowUnix: 1_800_000_000)
        guard case .unavailable = phase else { return XCTFail("missing dep → unavailable, got \(phase)") }
        let canOpen = await coord.canOpen
        XCTAssertFalse(canOpen, "no Open when a dependency is missing")
        let started = await coord.startedClient()
        XCTAssertNil(started)
    }

    func testTokenSigningFailureDoesNotOpen() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let coord = ClawShareOpenCoordinator(
            factory: FakeFactory(client: client),
            signer: StubSigner(result: .failure(SignerError()))
        )
        let phase = await coord.bringUp(Self.inputs(), nowUnix: 1_800_000_000)
        guard case .failed = phase else { return XCTFail("token sign failure → failed, got \(phase)") }
        let canOpen = await coord.canOpen
        XCTAssertFalse(canOpen)
        let started = await coord.startedClient()
        XCTAssertNil(started, "no client handed out without a signed token")
    }

    // MARK: - Inputs builder (host-side assembly from an accepted share)

    func testInputsBuilderRefusesWithoutStagedEndpoint() {
        // No endpoint staged yet → no inputs → host shows no "Open".
        let inputs = ClawShareOpenInputs.fromAcceptedShare(
            credentialCBOR: Self.cred, clawId: Self.claw, endpoint: nil
        )
        XCTAssertNil(inputs, "missing endpoint must yield no inputs (no fake Open)")
    }

    func testInputsBuilderRefusesEmptyCredential() {
        let inputs = ClawShareOpenInputs.fromAcceptedShare(
            credentialCBOR: Data(), clawId: Self.claw, endpoint: Self.endpoint
        )
        XCTAssertNil(inputs, "empty credential must yield no inputs")
    }

    func testInputsBuilderBindsCredentialAndTarget() {
        let inputs = ClawShareOpenInputs.fromAcceptedShare(
            credentialCBOR: Self.cred, clawId: Self.claw, endpoint: Self.endpoint
        )
        XCTAssertEqual(inputs?.credentialCBOR, Self.cred)
        XCTAssertEqual(inputs?.targetClawId, Self.claw, "target is the credential's claw, never operator input")
        XCTAssertEqual(inputs?.endpoint, Self.endpoint)
        XCTAssertTrue(inputs?.isComplete == true)
    }

    func testNonInteractiveOpenDoesNotShowOpen() async {
        // Engine reaches only streamReady (socket open, no output) → not openable.
        let client = FakeClient(openStatus: .streamReady(sinceUnix: 2))
        let coord = ClawShareOpenCoordinator(
            factory: FakeFactory(client: client),
            signer: StubSigner(result: .success(Data("token".utf8)))
        )
        let phase = await coord.bringUp(Self.inputs(), nowUnix: 1_800_000_000)
        guard case .failed = phase else { return XCTFail("streamReady → not openable, got \(phase)") }
        let canOpen = await coord.canOpen
        XCTAssertFalse(canOpen)
    }
}
