import CryptoKit
import Foundation
import XCTest
@testable import SoyehtCore

final class EngineHarnessTests: XCTestCase {
    private var harness: EngineHarness?

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let reason = EngineHarness.executionBlockReason {
            throw XCTSkip(reason)
        }
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    func testBootstrapStatusPassesProductionCompatibilityHandshake() async throws {
        let harness = try await bootEngine(case: .statusOnly)
        let statusClient = BootstrapStatusClient(baseURL: harness.baseURL)

        let status = try await statusClient.fetch()
        XCTAssertTrue(EngineCompat.isCompatible(status.engineVersion))
        try await EngineCompat.assertCompatible(via: statusClient)
        XCTAssertEqual(status.state, .uninitialized)
    }

    func testInitializeThenConfirmPairsWithSoftwareP256Owner() async throws {
        let harness = try await bootEngine(case: .initializePair)
        // The pairing URI is consumed EXACTLY from the initialize response —
        // the same boundary the iOS production onboarding uses (initialize →
        // `URL(string: response.pairQrUri)` guard → `PairDeviceQR`). No other
        // endpoint is contacted for the URI.
        let (stage, scannedPairQR) = try await PairQRConsumption.initializeAndScanPairQR(
            baseURL: harness.baseURL,
            transport: harness.initializeTransport(),
            name: syntheticHouseholdName()
        )

        let stagedStatus = try await BootstrapStatusClient(baseURL: harness.baseURL).fetch()
        XCTAssertEqual(stagedStatus.state, .namedAwaitingPair)
        XCTAssertEqual(stagedStatus.hhId, stage.hhId)
        XCTAssertEqual(stage.hhPub.count, HouseholdIdentifiers.compressedP256PublicKeyLength)
        XCTAssertEqual(try HouseholdIdentifiers.householdIdentifier(for: stage.hhPub), stage.hhId)
        // The pinned engine omits hh_pub from status while awaiting the first
        // pairing. Pin that observed contract rather than silently filling it
        // from initialize; a future engine change must update this test.
        XCTAssertNil(stagedStatus.hhPub)

        let owner = try SoftwareOwnerIdentity()
        XCTAssertEqual(scannedPairQR.householdPublicKey, stage.hhPub)
        XCTAssertEqual(scannedPairQR.householdId, stage.hhId)
        let request = try makePairConfirmRequest(pairQR: scannedPairQR, owner: owner)
        let confirmation = try await URLSessionHouseholdPairingHTTPClient().confirmPairing(
            endpoint: harness.baseURL,
            body: request
        )

        XCTAssertEqual(confirmation.v, 1)
        XCTAssertEqual(confirmation.householdId, stage.hhId)
        XCTAssertEqual(confirmation.personId, owner.personId)

        let readyStatus = try await BootstrapStatusClient(baseURL: harness.baseURL).fetch()
        XCTAssertEqual(readyStatus.state, .ready)
        XCTAssertEqual(readyStatus.deviceCount, 1)
    }

    func testOwnerEventsLongPollAcceptsPoPAndHoldsUntilClientCancellation() async throws {
        let harness = try await bootEngine(case: .longPoll)
        let (stage, scannedPairQR) = try await PairQRConsumption.initializeAndScanPairQR(
            baseURL: harness.baseURL,
            transport: harness.initializeTransport(),
            name: syntheticHouseholdName()
        )
        let owner = try SoftwareOwnerIdentity()
        let confirmation = try await URLSessionHouseholdPairingHTTPClient().confirmPairing(
            endpoint: harness.baseURL,
            body: try makePairConfirmRequest(pairQR: scannedPairQR, owner: owner)
        )
        XCTAssertEqual(confirmation.personId, owner.personId)

        let probe = OwnerEventsRequestProbe()
        let poller = OwnerEventsLongPoll(
            baseURL: harness.baseURL,
            householdId: stage.hhId,
            queue: JoinRequestQueue(),
            wordlist: try BIP39Wordlist(),
            configuration: .init(longPollTimeout: 8),
            popSigner: HouseholdPoPSigner(ownerIdentity: owner),
            eventVerifier: { _ in },
            transport: { request in
                await probe.record(request)
                return try await URLSession.shared.data(for: request)
            }
        )

        let completion = OwnerEventsPollCompletion()
        let pollTask = Task { () -> Error? in
            do {
                _ = try await poller.pollOnce()
                await completion.recordCompletion()
                return nil
            } catch {
                await completion.recordCompletion()
                return error
            }
        }
        // Keep teardown prompt even when a later assertion or probe wait fails
        // before the explicit cancellation below.
        defer { pollTask.cancel() }
        let request = try await probe.waitForRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/household/owner-events")
        XCTAssertEqual(request.url?.query, "since=AA")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:") == true)

        // A bad PoP or cursor returns immediately. A still-pending task after
        // two seconds demonstrates that the pinned engine accepted the signed
        // request and is holding the real long-poll; cancel rather than wait
        // for its fixed 45-second timeout.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let completedBeforeCancellation = await completion.didComplete()
        XCTAssertFalse(completedBeforeCancellation)
        pollTask.cancel()
        let result = await pollTask.value
        XCTAssertEqual(result as? MachineJoinError, .networkDrop)
    }

    private func bootEngine(case caseID: EngineHarness.HarnessCaseID) async throws -> EngineHarness {
        let booted = try await EngineHarness.boot(case: caseID)
        harness = booted
        return booted
    }

    private func syntheticHouseholdName() -> String {
        "HARNESS-TEST-\(UUID().uuidString.prefix(8).uppercased())"
    }

    private func makePairConfirmRequest(
        pairQR: PairDeviceQR,
        owner: SoftwareOwnerIdentity
    ) throws -> PairDeviceConfirmRequest {
        return try PairingProof.confirmRequest(
            qr: pairQR,
            ownerIdentity: owner,
            displayName: "Harness Owner"
        )
    }
}

private struct SoftwareOwnerIdentity: OwnerIdentitySigning {
    private let backing: InMemoryOwnerIdentityKey

    init() throws {
        let key = P256.Signing.PrivateKey()
        backing = try InMemoryOwnerIdentityKey(
            publicKey: key.publicKey.compressedRepresentation,
            keyReference: "engine-harness-software-owner"
        ) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }

    var personId: String { backing.personId }
    var publicKey: Data { backing.publicKey }
    var keyReference: String { backing.keyReference }

    func sign(_ payload: Data) throws -> Data {
        try backing.sign(payload)
    }
}

/// The single boundary error the URI-consumption helper can add on top of the
/// production parser: the response's `pairQrUri` was not even parseable as a
/// `URL` (which is how the engine's documented empty-string degradation
/// surfaces — `URL(string: "")` is nil on this platform).
enum PairQRConsumptionError: Error, Equatable {
    case uriNotParseableAsURL
}

/// Test-only orchestration shared by BOTH engine-booting cases: runs the real
/// `BootstrapInitializeClient.initialize` through the given transport, then
/// builds the `PairDeviceQR` EXACTLY from `response.pairQrUri` — the same
/// consumption boundary the iOS production onboarding uses (initialize →
/// `URL(string: response.pairQrUri)` guard → `PairDeviceQR(url:)`). No other
/// endpoint is contacted for the URI: the initialize response already carries
/// every field the parser requires. `parse` is a seam so fixtures can observe
/// the exact String consumed; its default is the real consumption boundary.
enum PairQRConsumption {
    static func initializeAndScanPairQR(
        baseURL: URL,
        transport: @escaping BootstrapInitializeClient.TransportPerform,
        name: String,
        parse: (String) throws -> PairDeviceQR = PairQRConsumption.parsePairQR
    ) async throws -> (stage: BootstrapInitializeResponse, qr: PairDeviceQR) {
        let stage = try await BootstrapInitializeClient(baseURL: baseURL, transport: transport)
            .initialize(name: name, claimToken: nil)
        let qr = try parse(stage.pairQrUri)
        return (stage, qr)
    }

    /// The production consumption boundary, split factually: `URL(string:)`
    /// fails closed on a non-URL (its own error), then the real `PairDeviceQR`
    /// parser validates scheme/path/fields (its own typed errors).
    static func parsePairQR(from uri: String) throws -> PairDeviceQR {
        guard let url = URL(string: uri) else {
            throw PairQRConsumptionError.uriNotParseableAsURL
        }
        return try PairDeviceQR(url: url)
    }
}

private actor OwnerEventsRequestProbe {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func waitForRequest() async throws -> URLRequest {
        for _ in 0..<200 {
            if let request {
                return request
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw URLError(.timedOut)
    }
}

private actor OwnerEventsPollCompletion {
    private var completed = false

    func recordCompletion() {
        completed = true
    }

    func didComplete() -> Bool {
        completed
    }
}
