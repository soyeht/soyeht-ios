import CryptoKit
import XCTest
import SoyehtCore
@testable import Soyeht

final class APNSRegistrationCoordinatorTests: XCTestCase {
    func testInitialRegisterBuildsPoPAuthenticatedCBORWithoutHouseholdId() async throws {
        let session = makeHouseholdState(householdId: "hh_test")
        let sessionBox = SessionBox(session)
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = APNSRegistrationTransportProbe()
        let coordinator = makeCoordinator(
            sessionBox: sessionBox,
            stateStore: stateStore,
            transport: transport
        )
        let token = Data([0x01, 0x02, 0x03, 0x04])

        let registered = try await coordinator.receiveDeviceToken(token)

        XCTAssertTrue(registered)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://casa.local:8443/api/v1/household/owner-device/push-token")
        XCTAssertEqual(request.pathAndQuery, "/api/v1/household/owner-device/push-token")
        XCTAssertEqual(request.authorizationHeader, "Soyeht-PoP test")
        XCTAssertEqual(request.householdId, "hh_test")
        XCTAssertEqual(request.tokenHash, APNSRegistrationCoordinator.tokenHash(token))

        guard case .map(let body) = try HouseholdCBOR.decode(request.body) else {
            return XCTFail("APNS registration body must be a CBOR map")
        }
        XCTAssertEqual(Set(body.keys), ["platform", "push_token", "v"])
        XCTAssertEqual(body["platform"], .text("ios"))
        XCTAssertEqual(body["push_token"], .bytes(token))
        XCTAssertEqual(body["v"], .unsigned(1))
        XCTAssertNil(body["hh_id"])

        XCTAssertEqual(stateStore.load()?.householdId, "hh_test")
        XCTAssertEqual(stateStore.load()?.tokenHash, APNSRegistrationCoordinator.tokenHash(token))
    }

    func testTokenRotationRegistersNewTokenAndIdenticalTokenIsDeduped() async throws {
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = APNSRegistrationTransportProbe()
        let coordinator = makeCoordinator(
            stateStore: stateStore,
            transport: transport
        )
        let originalToken = Data([0xAA, 0x01])
        let rotatedToken = Data([0xAA, 0x02])

        let originalRegistered = try await coordinator.receiveDeviceToken(originalToken)
        let duplicateRegistered = try await coordinator.receiveDeviceToken(originalToken)
        let rotatedRegistered = try await coordinator.receiveDeviceToken(rotatedToken)

        XCTAssertTrue(originalRegistered)
        XCTAssertFalse(duplicateRegistered)
        XCTAssertTrue(rotatedRegistered)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        guard case .map(let firstBody) = try HouseholdCBOR.decode(requests[0].body),
              case .map(let secondBody) = try HouseholdCBOR.decode(requests[1].body) else {
            return XCTFail("Expected CBOR maps")
        }
        XCTAssertEqual(firstBody["push_token"], .bytes(originalToken))
        XCTAssertEqual(secondBody["push_token"], .bytes(rotatedToken))
        XCTAssertEqual(stateStore.load()?.tokenHash, APNSRegistrationCoordinator.tokenHash(rotatedToken))
    }

    func testTokenRotationWhileRegistrationIsInFlightRetriesLatestToken() async throws {
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = BlockingAPNSRegistrationTransport()
        let coordinator = makeCoordinator(
            stateStore: stateStore,
            transport: APNSRegistrationTransportProbe(),
            transportOverride: { request in
                await transport.record(request)
            }
        )
        let originalToken = Data([0xAA, 0x10])
        let rotatedToken = Data([0xAA, 0x20])

        let originalTask = Task {
            try await coordinator.receiveDeviceToken(originalToken)
        }
        await transport.waitForRequestCount(1)

        let rotatedImmediateResult = try await coordinator.receiveDeviceToken(rotatedToken)
        XCTAssertFalse(rotatedImmediateResult)

        await transport.releaseNext()
        await transport.waitForRequestCount(2)
        await transport.releaseNext()

        let originalResult = try await originalTask.value
        XCTAssertTrue(originalResult)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        guard case .map(let firstBody) = try HouseholdCBOR.decode(requests[0].body),
              case .map(let secondBody) = try HouseholdCBOR.decode(requests[1].body) else {
            return XCTFail("Expected CBOR maps")
        }
        XCTAssertEqual(firstBody["push_token"], .bytes(originalToken))
        XCTAssertEqual(secondBody["push_token"], .bytes(rotatedToken))
        XCTAssertEqual(stateStore.load()?.tokenHash, APNSRegistrationCoordinator.tokenHash(rotatedToken))
    }

    func testSessionClearDeletesLocalStateWithoutNetworkDeregisterAndSuppressesUntilNewSession() async throws {
        let sessionBox = SessionBox(makeHouseholdState(householdId: "hh_old"))
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = APNSRegistrationTransportProbe()
        let coordinator = makeCoordinator(
            sessionBox: sessionBox,
            stateStore: stateStore,
            transport: transport
        )
        let token = Data([0x10, 0x20, 0x30])

        let initialRegistered = try await coordinator.receiveDeviceToken(token)
        XCTAssertTrue(initialRegistered)
        await transport.waitForRequestCount(1)

        sessionBox.session = nil
        await coordinator.clearSession()
        XCTAssertNil(stateStore.load())
        let foregroundWithoutSessionRegistered = try await coordinator.handleForeground()
        let tokenWithoutSessionRegistered = try await coordinator.receiveDeviceToken(Data([0x40, 0x50]))
        let requestsAfterClear = await transport.requests()
        XCTAssertFalse(foregroundWithoutSessionRegistered)
        XCTAssertFalse(tokenWithoutSessionRegistered)
        XCTAssertEqual(requestsAfterClear.count, 1)

        sessionBox.session = makeHouseholdState(householdId: "hh_new")
        let newSessionRegistered = try await coordinator.handleSessionActivated()
        let requestsAfterNewSession = await transport.requests()
        XCTAssertTrue(newSessionRegistered)
        XCTAssertEqual(requestsAfterNewSession.count, 2)
        XCTAssertEqual(stateStore.load()?.householdId, "hh_new")
    }

    func testForegroundReRegistersWhenLocalStateIsMissingOrStale() async throws {
        let nowBox = TimeBox(Date(timeIntervalSince1970: 1_700_000_000))
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = APNSRegistrationTransportProbe()
        let coordinator = makeCoordinator(
            stateStore: stateStore,
            transport: transport,
            nowBox: nowBox,
            staleAfter: 10
        )
        let token = Data([0x0A, 0x0B])

        let initialRegistered = try await coordinator.receiveDeviceToken(token)
        XCTAssertTrue(initialRegistered)
        await transport.waitForRequestCount(1)

        stateStore.clear()
        let missingStateRegistered = try await coordinator.handleForeground()
        XCTAssertTrue(missingStateRegistered)
        await transport.waitForRequestCount(2)

        nowBox.now = nowBox.now.addingTimeInterval(11)
        let staleStateRegistered = try await coordinator.handleForeground()
        XCTAssertTrue(staleStateRegistered)
        await transport.waitForRequestCount(3)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
    }

    func testUnknownTokenReportForcesNextForegroundRegistration() async throws {
        let stateStore = InMemoryAPNSRegistrationStateStore()
        let transport = APNSRegistrationTransportProbe()
        let coordinator = makeCoordinator(
            stateStore: stateStore,
            transport: transport
        )
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let initialRegistered = try await coordinator.receiveDeviceToken(token)
        let dedupedForegroundRegistered = try await coordinator.handleForeground()
        XCTAssertTrue(initialRegistered)
        XCTAssertFalse(dedupedForegroundRegistered)

        await coordinator.markTokenUnknown()
        let unknownTokenRegistered = try await coordinator.handleForeground()
        XCTAssertTrue(unknownTokenRegistered)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
    }

    private func makeCoordinator(
        sessionBox: SessionBox? = nil,
        stateStore: InMemoryAPNSRegistrationStateStore,
        transport: APNSRegistrationTransportProbe,
        transportOverride: APNSRegistrationCoordinator.Transport? = nil,
        nowBox: TimeBox = TimeBox(Date(timeIntervalSince1970: 1_700_000_000)),
        staleAfter: TimeInterval = APNSRegistrationCoordinator.staleAfter
    ) -> APNSRegistrationCoordinator {
        let resolvedSessionBox = sessionBox ?? SessionBox(makeHouseholdState(householdId: "hh_test"))
        return APNSRegistrationCoordinator(
            sessionProvider: {
                resolvedSessionBox.session
            },
            authorizationProvider: { _, method, pathAndQuery, body in
                XCTAssertEqual(method, "POST")
                XCTAssertEqual(pathAndQuery, APNSRegistrationCoordinator.registrationPath)
                XCTAssertFalse(body.isEmpty)
                return "Soyeht-PoP test"
            },
            transport: transportOverride ?? { request in
                await transport.record(request)
            },
            stateStore: stateStore,
            nowProvider: {
                nowBox.now
            },
            staleAfter: staleAfter
        )
    }

    private func makeHouseholdState(householdId: String) -> ActiveHouseholdState {
        let ownerPublicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let householdPublicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: householdId,
            personId: "p_test",
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:\(householdId)",
            signature: Data(repeating: 0x11, count: 64)
        )
        return ActiveHouseholdState(
            householdId: householdId,
            householdName: "Casa",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://casa.local:8443")!,
            ownerPersonId: "p_test",
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }
}

private actor BlockingAPNSRegistrationTransport {
    private var recorded: [APNSRegistrationRequest] = []
    private var responseContinuations: [CheckedContinuation<APNSRegistrationAck, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ request: APNSRegistrationRequest) async -> APNSRegistrationAck {
        recorded.append(request)
        resumeSatisfiedWaiters()
        return await withCheckedContinuation { continuation in
            responseContinuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !responseContinuations.isEmpty else { return }
        let continuation = responseContinuations.removeFirst()
        continuation.resume(returning: APNSRegistrationAck(updatedAt: UInt64(1_700_000_000 + recorded.count)))
    }

    func requests() -> [APNSRegistrationRequest] {
        recorded
    }

    func waitForRequestCount(_ count: Int) async {
        guard recorded.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if recorded.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }
}

private actor APNSRegistrationTransportProbe {
    private var recorded: [APNSRegistrationRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ request: APNSRegistrationRequest) -> APNSRegistrationAck {
        recorded.append(request)
        resumeSatisfiedWaiters()
        return APNSRegistrationAck(updatedAt: UInt64(1_700_000_000 + recorded.count))
    }

    func requests() -> [APNSRegistrationRequest] {
        recorded
    }

    func waitForRequestCount(_ count: Int) async {
        guard recorded.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if recorded.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }
}

private final class InMemoryAPNSRegistrationStateStore: APNSRegistrationStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: APNSRegistrationState?

    func load() -> APNSRegistrationState? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ state: APNSRegistrationState) {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        state = nil
    }
}

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ActiveHouseholdState?

    init(_ session: ActiveHouseholdState?) {
        stored = session
    }

    var session: ActiveHouseholdState? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

private final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ date: Date) {
        stored = date
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
