import XCTest
import SoyehtCore
@testable import Soyeht

/// App-target contract for the real "Open" entry-point (`ClawShareOpenController`).
///
/// Drives the controller against a fake factory + stub signer + fixed
/// endpoint (the fakes live ONLY here, never on the product path). Asserts:
/// reaching `.interactiveReady` reveals Open and hands out the live client;
/// the production default factory is the real bridge factory (not a fake);
/// a missing endpoint shows no Open and presents no terminal; the SE token
/// signer is invoked on the real path; and closing clears the launch (no
/// zombie). Not CI-gated (CI builds the app, not its unit tests);
/// reproducible via `xcodebuild test -scheme Soyeht`.
@MainActor
final class ClawShareOpenFlowTests: XCTestCase {
    private static let endpoint = ClawShareDataPlaneEndpoint(host: "192.168.15.13", port: 7423)

    private static func credential(claw: String = "claw_test") -> GuestCredential {
        GuestCredential(
            householdId: "hh", ownerPersonId: "owner",
            ownerPublicKey: Data(repeating: 0x01, count: 33),
            clawId: claw,
            guestDevicePublicKey: Data(repeating: 0x02, count: 33),
            slotId: Data(repeating: 0x03, count: 16),
            issuedAt: 1_800_000_000, expiresAt: 1_800_900_000,
            ownerSignature: Data(repeating: 0x04, count: 64)
        )
    }

    /// Fake client: open reaches the scriptable status; records the token it
    /// was started with so we can prove the signed token was forwarded.
    private actor FakeClient: ClawShareDataPlaneClient {
        let openStatus: ClawShareSessionStatus
        private(set) var startedToken: Data?
        init(openStatus: ClawShareSessionStatus) { self.openStatus = openStatus }
        func loadCredential(_ c: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus { .credentialReady }
        func startSession(endpoint: ClawShareDataPlaneEndpoint, sessionToken: Data) async throws -> ClawShareStartOutcome {
            startedToken = sessionToken
            return ClawShareStartOutcome(meshIPv6: "fd00::1", mtu: 1280, sessionId: "t", status: .awaitingFirstPacket)
        }
        func healthPing() async throws -> ClawShareSessionStatus { .connected(sinceUnix: 1) }
        func openStream() async throws -> ClawShareSessionStatus { openStatus }
        func sendData(_ packet: Data) async throws {}
        func receiveData() async throws -> Data { Data() }
        func resize(cols: UInt16, rows: UInt16) async throws {}
        func currentStatus() async -> ClawShareSessionStatus { openStatus }
        func stopSession(reason: String) async -> ClawShareSessionStatus { .stopped(reason: reason) }
        func token() async -> Data? { startedToken }
    }

    private struct FakeFactory: ClawShareDataPlaneClientFactory {
        let client: FakeClient
        func makeClient() -> any ClawShareDataPlaneClient { client }
    }

    /// Stub signer that records it was asked to sign (proves the SE-signing
    /// step runs on the real bring-up path).
    private final class RecordingSigner: ClawShareSessionTokenSigning, @unchecked Sendable {
        private(set) var signedCount = 0
        private(set) var lastTargetId: String?
        let token: Data
        init(token: Data) { self.token = token }
        func signedToken(sessionId: String, credentialCBOR: Data, endpoint: String, targetId: String, nonce: Data, expiresAtUnix: UInt64) throws -> Data {
            signedCount += 1
            lastTargetId = targetId
            return token
        }
    }

    private func makeController(
        client: FakeClient,
        signer: RecordingSigner,
        endpoint: ClawShareDataPlaneEndpoint? = endpoint
    ) -> ClawShareOpenController {
        ClawShareOpenController(
            identityProvider: EphemeralClawShareGuestIdentityProvider(),
            factory: FakeFactory(client: client),
            signer: signer,
            endpointProvider: { endpoint }
        )
    }

    func testInteractiveReadyRevealsOpenAndSignsToken() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let signer = RecordingSigner(token: Data("tok".utf8))
        let controller = makeController(client: client, signer: signer)

        await controller.prepare(credential: Self.credential(), nowUnix: 1_800_000_000)

        XCTAssertTrue(controller.canOpen, "interactiveReady → Open shown")
        XCTAssertEqual(signer.signedCount, 1, "SE token signer MUST be called on the real path")
        XCTAssertEqual(signer.lastTargetId, "claw_test", "token binds the credential's claw")
        let forwarded = await client.token()
        XCTAssertEqual(forwarded, Data("tok".utf8), "the signed token is forwarded to startSession")
    }

    func testOpenPresentsTerminalWithLiveClient() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let controller = makeController(client: client, signer: RecordingSigner(token: Data("tok".utf8)))
        await controller.prepare(credential: Self.credential(), nowUnix: 1_800_000_000)

        XCTAssertNil(controller.launch)
        await controller.open(displayName: "claw_test")
        XCTAssertNotNil(controller.launch, "Open presents the terminal with the live client")
        XCTAssertEqual(controller.launch?.displayName, "claw_test")
    }

    func testMissingEndpointShowsNoOpenAndNoTerminal() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let signer = RecordingSigner(token: Data("tok".utf8))
        let controller = makeController(client: client, signer: signer, endpoint: nil)

        await controller.prepare(credential: Self.credential(), nowUnix: 1_800_000_000)

        XCTAssertFalse(controller.canOpen, "no endpoint → no Open")
        XCTAssertEqual(signer.signedCount, 0, "no dial / no signing without an endpoint")
        await controller.open(displayName: "claw_test")
        XCTAssertNil(controller.launch, "no terminal presented without a live session")
    }

    func testNonInteractiveDoesNotOpen() async {
        // Stream opened but never reached interactiveReady → not openable.
        let client = FakeClient(openStatus: .streamReady(sinceUnix: 2))
        let controller = makeController(client: client, signer: RecordingSigner(token: Data("tok".utf8)))
        await controller.prepare(credential: Self.credential(), nowUnix: 1_800_000_000)
        XCTAssertFalse(controller.canOpen)
        await controller.open(displayName: "claw_test")
        XCTAssertNil(controller.launch)
    }

    func testTerminalClosedClearsLaunchNoZombie() async {
        let client = FakeClient(openStatus: .interactiveReady(sinceUnix: 9))
        let controller = makeController(client: client, signer: RecordingSigner(token: Data("tok".utf8)))
        await controller.prepare(credential: Self.credential(), nowUnix: 1_800_000_000)
        await controller.open(displayName: "claw_test")
        XCTAssertNotNil(controller.launch)

        controller.terminalClosed()
        XCTAssertNil(controller.launch, "closing the terminal clears the launch — no zombie, gate re-enterable")
    }

    func testProductionDefaultFactoryIsTheRealBridgeFactory() {
        // Defense in depth: the default factory must be the production type,
        // never a fake. The fake factory only exists in this test file.
        let controller = ClawShareOpenController(
            identityProvider: EphemeralClawShareGuestIdentityProvider()
        )
        let mirror = Mirror(reflecting: controller)
        let factory = mirror.children.first { $0.label == "factory" }?.value
        XCTAssertTrue(
            factory is ProductionClawShareDataPlaneClientFactory,
            "production controller MUST default to the real bridge factory"
        )
    }
}
