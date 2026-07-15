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
        let harness = try await bootEngine()
        let statusClient = BootstrapStatusClient(baseURL: harness.baseURL)

        let status = try await statusClient.fetch()
        XCTAssertTrue(EngineCompat.isCompatible(status.engineVersion))
        try await EngineCompat.assertCompatible(via: statusClient)
        XCTAssertEqual(status.state, .uninitialized)
    }

    func testInitializeThenConfirmPairsWithSoftwareP256Owner() async throws {
        let harness = try await bootEngine()
        let stage = try await BootstrapInitializeClient(baseURL: harness.baseURL)
            .initialize(name: syntheticHouseholdName(), claimToken: nil)

        let stagedStatus = try await BootstrapStatusClient(baseURL: harness.baseURL).fetch()
        XCTAssertEqual(stagedStatus.state, .namedAwaitingPair)
        XCTAssertEqual(stagedStatus.hhId, stage.hhId)
        // theyos 0.1.21 omits hh_pub from status while awaiting the first
        // pairing. The initialize response is the authoritative source at
        // this stage; readiness and the confirm response below prove the
        // resulting household identity.

        let owner = try SoftwareOwnerIdentity()
        // The physical world reads this URI from the Mac's QR code. The iPhone
        // production surface has no initiate client, so this test-only double
        // models the camera scan while the mutation stays on production clients.
        let scannedPairURI = try await QRScanSimulator.scanPairDeviceURI(endpoint: harness.baseURL)
        let request = try makePairConfirmRequest(pairURI: scannedPairURI, owner: owner)
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
        let harness = try await bootEngine()
        let stage = try await BootstrapInitializeClient(baseURL: harness.baseURL)
            .initialize(name: syntheticHouseholdName(), claimToken: nil)
        let owner = try SoftwareOwnerIdentity()
        let confirmation = try await URLSessionHouseholdPairingHTTPClient().confirmPairing(
            endpoint: harness.baseURL,
            body: try makePairConfirmRequest(
                pairURI: try await QRScanSimulator.scanPairDeviceURI(endpoint: harness.baseURL),
                owner: owner
            )
        )
        XCTAssertEqual(confirmation.personId, owner.personId)

        let probe = OwnerEventsRequestProbe()
        let poller = OwnerEventsLongPoll(
            baseURL: harness.baseURL,
            householdId: stage.hhId,
            queue: JoinRequestQueue(),
            wordlist: try BIP39Wordlist(),
            configuration: .init(longPollTimeout: 3),
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

    private func bootEngine() async throws -> EngineHarness {
        let booted = try await EngineHarness.boot()
        harness = booted
        return booted
    }

    private func syntheticHouseholdName() -> String {
        "HARNESS-TEST-\(UUID().uuidString.prefix(8).uppercased())"
    }

    private func makePairConfirmRequest(
        pairURI: URL,
        owner: SoftwareOwnerIdentity
    ) throws -> PairDeviceConfirmRequest {
        return try PairingProof.confirmRequest(
            qr: PairDeviceQR(url: pairURI),
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

/// Test-only stand-in for the physical camera reading the URI the Mac exposes.
/// It exists because no SoyehtCore production client consumes `initiate` today.
private enum QRScanSimulator {
    private struct InitiateResponse: Decodable {
        let uri: String
    }

    static func scanPairDeviceURI(endpoint: URL) async throws -> URL {
        var request = URLRequest(
            url: endpoint.appending(path: "/api/v1/household/pair-device/initiate")
        )
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let uri = URL(string: try JSONDecoder().decode(InitiateResponse.self, from: data).uri) else {
            throw URLError(.badServerResponse)
        }
        return uri
    }
}

private actor OwnerEventsRequestProbe {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func waitForRequest() async throws -> URLRequest {
        for _ in 0..<80 {
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
