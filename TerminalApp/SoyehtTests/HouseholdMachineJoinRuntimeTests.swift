import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

final class HouseholdMachineJoinRuntimeTests: XCTestCase {
    private let originalTTL: UInt64 = 1_700_000_300
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - cappedStagedTTL — symmetric expiry validation

    func testStagingExpiryShorterThanQRTTLIsAccepted() throws {
        let capped = try HouseholdMachineJoinRuntime.cappedStagedTTL(
            originalTTLUnix: originalTTL,
            acceptedExpiry: 1_700_000_120,
            now: now
        )
        XCTAssertEqual(capped, 1_700_000_120)
    }

    func testStagingExpiryCannotExtendOriginalQRHardTTL() throws {
        let capped = try HouseholdMachineJoinRuntime.cappedStagedTTL(
            originalTTLUnix: originalTTL,
            acceptedExpiry: 1_700_001_000,
            now: now
        )
        XCTAssertEqual(capped, originalTTL)
    }

    func testStagingExpiryZeroIsRejected() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 0,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testStagingExpiryInThePastIsRejected() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 1_699_999_999,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testStagingExpiryEqualToNowIsRejected() {
        // `min(original, now)` would still leave a request that the queue's
        // `claim` immediately expires; reject explicitly so the staging
        // layer surfaces the protocol issue instead of letting the queue
        // silently drop the entry.
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 1_700_000_000,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testOriginalQRTTLInPastIsRejectedAsQRExpired() {
        // Symmetric defence: clock skew or a QR sitting in the scanner
        // buffer past its own TTL must fail closed at the staging
        // boundary instead of relying on `JoinRequestQueue.claim` to
        // silently drop a permanently-expired entry. The error type is
        // `qrExpired` (not `protocolViolation`) so the operator gets the
        // right localized message — the QR is the stale party here.
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: 1_699_999_500,
                acceptedExpiry: 1_700_000_500,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MachineJoinError, .qrExpired)
        }
    }

    func testOriginalQRTTLEqualToNowIsRejectedAsQRExpired() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: 1_700_000_000,
                acceptedExpiry: 1_700_000_500,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MachineJoinError, .qrExpired)
        }
    }

    // MARK: - Confirm-snapshot lifecycle (round-4 P1/P2 hardening)

    @MainActor
    func testBeginConfirmingPublishesSnapshotAndDerivedKey() {
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xA1, ttl: originalTTL)
        let key = request.envelope.idempotencyKey

        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)

        runtime.beginConfirming(request)

        XCTAssertEqual(runtime.confirmingRequest, request)
        XCTAssertEqual(runtime.confirmingRequestKey, key)
    }

    @MainActor
    func testEndConfirmingClearsSnapshotForMatchingKey() {
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xA2, ttl: originalTTL)
        let key = request.envelope.idempotencyKey

        runtime.beginConfirming(request)
        XCTAssertEqual(runtime.confirmingRequestKey, key)

        runtime.endConfirming(key)
        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)
    }

    @MainActor
    func testEndConfirmingIsIdempotentOnMismatch() {
        // `onChange`/`onDisappear` from a previously-displayed CardHost
        // must not clear the snapshot of a *newer* confirm. The runtime
        // gate is the idempotency-key match.
        let runtime = HouseholdMachineJoinRuntime()
        let newer = Self.makePendingRequest(nonceByte: 0xB1, ttl: originalTTL)
        let newerKey = newer.envelope.idempotencyKey

        runtime.beginConfirming(newer)
        XCTAssertEqual(runtime.confirmingRequestKey, newerKey)

        // A stale teardown for an older (different) request must not
        // touch the current snapshot.
        let stalerKey = Self.makePendingRequest(nonceByte: 0xC9, ttl: originalTTL)
            .envelope.idempotencyKey
        XCTAssertNotEqual(stalerKey, newerKey)
        runtime.endConfirming(stalerKey)
        XCTAssertEqual(runtime.confirmingRequestKey, newerKey)
    }

    @MainActor
    func testSnapshotSurvivesQueueRemoval() {
        // The whole point of the snapshot is to outlive the queue
        // entry. Once `beginConfirming` lands, the runtime must keep
        // the request available even if the queue has dropped it
        // (gossip ack mid-confirm, terminal failure, success path).
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xD3, ttl: originalTTL)

        runtime.beginConfirming(request)

        // The runtime exposes a snapshot independent of pendingRequests,
        // so a (hypothetical) external clear of the queue must not
        // disturb it. We simulate by asserting the snapshot is still
        // accessible without consulting `pendingRequests`.
        XCTAssertEqual(runtime.confirmingRequest, request)
        XCTAssertEqual(runtime.pendingRequests, [])
    }

    @MainActor
    func testStopClearsConfirmingSnapshot() {
        // Logout / household switch in the middle of a confirm must NOT
        // leak the snapshot to the next activation. `stop()` is the
        // single source of teardown — it must reset the lock with the
        // rest of the lifecycle state.
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xE7, ttl: originalTTL)

        runtime.beginConfirming(request)
        XCTAssertNotNil(runtime.confirmingRequest)

        runtime.stop()

        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)
    }

    // MARK: - Lifecycle phase ordering — T037 invariant

    /// `stop()` on a runtime that never activated must still emit the full
    /// `.stopRequested` → `.stopCompleted` boundary pair. The contract is
    /// observable, not "nothing happens"; `SSHLoginView` may issue stops
    /// defensively (logout flow, household swap mid-restore) and we want
    /// the observer to see those calls so future regressions that swallow
    /// `stop()` are caught.
    @MainActor
    func testStopBeforeActivateEmitsBoundaryPair() {
        let recorder = LifecyclePhaseRecorder()
        let runtime = HouseholdMachineJoinRuntime(phaseObserver: recorder.append)

        runtime.stop()

        XCTAssertEqual(recorder.phases, [.stopRequested, .stopCompleted])
        XCTAssertNil(runtime.lifecycleError)
        XCTAssertNil(runtime.confirmingRequest)
    }

    /// `stop()` is idempotent. Three consecutive calls must produce three
    /// boundary pairs and never throw or leave inconsistent state — this
    /// guards `SSHLoginView` paths that call `stop()` on every household
    /// state transition.
    @MainActor
    func testStopIsIdempotent() {
        let recorder = LifecyclePhaseRecorder()
        let runtime = HouseholdMachineJoinRuntime(phaseObserver: recorder.append)

        runtime.stop()
        runtime.stop()
        runtime.stop()

        XCTAssertEqual(
            recorder.phases,
            [.stopRequested, .stopCompleted, .stopRequested, .stopCompleted, .stopRequested, .stopCompleted]
        )
    }

    /// Failure isolation: any error thrown during activation —
    /// owner-identity load, CRL store creation, snapshot transport, or
    /// signature verification — must (a) never let `.gossipStarted` or
    /// `.ownerEventsStarted` fire, and (b) emit `.activationFailed` so setup
    /// and snapshot failures share one terminal phase.
    ///
    /// The fixture activates against a synthetic `ownerKeyReference` that
    /// is not present in the Secure Enclave, so `loadOwnerIdentity` throws
    /// before any network I/O and we observe the zero-leak property.
    @MainActor
    func testActivationFailureNeverLeaksPastSnapshotCompletion() async {
        let recorder = LifecyclePhaseRecorder()
        let runtime = HouseholdMachineJoinRuntime(phaseObserver: recorder.append)
        let household = Self.makeUnreachableHousehold()

        runtime.activate(household)
        await Self.waitFor(timeout: 5) { runtime.lifecycleError != nil }

        XCTAssertNotNil(runtime.lifecycleError)
        XCTAssertTrue(
            recorder.phases.contains(.activationFailed),
            "Failure path must emit .activationFailed so activation has a terminal phase"
        )
        if let startIndex = recorder.phases.firstIndex(of: .snapshotStarted) {
            let failIndex = recorder.phases.firstIndex(of: .activationFailed)
            XCTAssertNotNil(
                failIndex,
                ".snapshotStarted must be paired with a later terminal when failure follows snapshot start"
            )
            if let failIndex {
                XCTAssertGreaterThan(failIndex, startIndex)
            }
        }
        XCTAssertFalse(
            recorder.phases.contains(.snapshotCompleted),
            "Snapshot bootstrap must not report completion when activation fails"
        )
        XCTAssertFalse(
            recorder.phases.contains(.gossipStarted),
            "Gossip must not start while the snapshot bootstrap has not completed"
        )
        XCTAssertFalse(
            recorder.phases.contains(.ownerEventsStarted),
            "Owner-events long-poll must not start without a successful snapshot + gossip handshake"
        )
    }

    /// Closes the long-standing activation-order gap at the head of this file: under
    /// successful activation, the runtime must cross
    /// `.snapshotStarted → .snapshotCompleted → .gossipStarted →
    /// .ownerEventsStarted` in that **exact order** — the protocol
    /// invariant that gossip cannot start before the snapshot has
    /// atomically seeded `CRLStore` + `HouseholdMembershipStore`, and
    /// owner-events cannot start before gossip is wired.
    ///
    /// Stubbed via `HouseholdRuntimeStubURLProtocol` for the snapshot
    /// fetch (signed CBOR root-validated by the bootstrapper) and for
    /// the owner-events long-poll (204 keeps the coordinator quiet).
    /// The gossip WebSocket bypasses `URLProtocol` — `startGossip` is
    /// synchronous, so `.gossipStarted` fires before any WS connect
    /// attempt and the boundary observation is unaffected by the WS
    /// connection's eventual success / failure.
    @MainActor
    func testHappyPathActivationCrossesPhasesInForwardOrder() async throws {
        HouseholdRuntimeStubURLProtocol.reset()
        defer { HouseholdRuntimeStubURLProtocol.reset() }

        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x21, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let ownerPersonId = try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey)

        let snapshotBytes = try MachineJoinTestFixtures.signedHouseholdSnapshot(
            householdPrivateKey: householdKey,
            householdId: householdId
        )

        HouseholdRuntimeStubURLProtocol.responder = { request in
            guard let path = request.url?.path else { return (500, Data(), [:]) }
            if path == "/api/v1/household/snapshot" {
                return (200, snapshotBytes, ["Content-Type": "application/cbor"])
            }
            if path == "/api/v1/household/owner-events" {
                // 204 keeps the coordinator on its long-poll loop without
                // surfacing any join request — the test only cares about
                // whether the coordinator started, not what it received.
                return (204, Data(), [:])
            }
            return (500, Data(), [:])
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HouseholdRuntimeStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let crlStore = try CRLStore(
            storage: TestInMemoryHouseholdStorage(),
            account: UUID().uuidString
        )
        let recorder = LifecyclePhaseRecorder()
        let runtime = HouseholdMachineJoinRuntime(
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: ownerKey),
            crlStore: crlStore,
            gossipCursorStore: TestInMemoryGossipCursorStore(),
            session: session,
            phaseObserver: recorder.append
        )

        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: householdId,
            personId: ownerPersonId,
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: householdId,
            signature: Data(repeating: 0x11, count: 64)
        )
        // Use a host that resolves but refuses TCP fast so the gossip
        // WebSocket fails immediately in background without delaying the
        // boundary observation. `127.0.0.1:1` is a privileged-port refuse
        // that drops the connection inside one syscall.
        let household = ActiveHouseholdState(
            householdId: householdId,
            householdName: "PhaseTest",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://127.0.0.1:1")!,
            ownerPersonId: ownerPersonId,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "stub-owner-key",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )

        runtime.activate(household)
        await Self.waitFor(timeout: 5) {
            recorder.phases.contains(.ownerEventsStarted)
        }
        runtime.stop()

        // `activate(_:)` defensively calls `stop()` to clear any prior
        // session before starting (runtime.swift:120), which emits a
        // `stopRequested → stopCompleted` boundary pair before the
        // activation work begins. The forward-order invariant is on
        // the activation phases themselves — extract the slice that
        // starts at `.snapshotStarted` and assert it.
        guard let snapshotIndex = recorder.phases.firstIndex(of: .snapshotStarted) else {
            XCTFail("Activation never emitted .snapshotStarted; recorded phases: \(recorder.phases)")
            return
        }
        let activationPhases = recorder.phases[snapshotIndex...]
            .prefix { $0 != .stopRequested }
        XCTAssertEqual(
            Array(activationPhases),
            [.snapshotStarted, .snapshotCompleted, .gossipStarted, .ownerEventsStarted],
            "Forward boundary order broken; recorded phases: \(recorder.phases)"
        )
        XCTAssertFalse(
            recorder.phases.contains(.activationFailed),
            "Happy path emitted .activationFailed; recorded phases: \(recorder.phases)"
        )
        // Sanity: the initial boundary pair from the defensive
        // `stop()` inside `activate(_:)` MUST come before any
        // activation phase. If a regression rearranged that, the
        // snapshot would be running against a stale session's CRL.
        XCTAssertEqual(recorder.phases.first, .stopRequested)
        XCTAssertEqual(recorder.phases[1], .stopCompleted)
    }

    /// `stop()` issued before the activation Task can reach the snapshot
    /// boundary must cancel the activation cleanly: no gossip /
    /// owner-events phases ever fire, and the stop boundary pair is
    /// recorded.
    @MainActor
    func testStopRacedAgainstActivationCancelsBeforeGossip() async {
        let recorder = LifecyclePhaseRecorder()
        let runtime = HouseholdMachineJoinRuntime(phaseObserver: recorder.append)
        let household = Self.makeUnreachableHousehold()

        runtime.activate(household)
        runtime.stop()

        // Give any inflight async cancellation a tick to settle so a
        // late `.snapshotCompleted` would have surfaced if the activation
        // Task somehow outraced the token rotation.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(recorder.phases.contains(.stopRequested))
        XCTAssertTrue(recorder.phases.contains(.stopCompleted))
        XCTAssertFalse(recorder.phases.contains(.gossipStarted))
        XCTAssertFalse(recorder.phases.contains(.ownerEventsStarted))
        if let startIndex = recorder.phases.firstIndex(of: .snapshotStarted) {
            let terminalIndices = [
                recorder.phases.firstIndex(of: .snapshotCompleted),
                recorder.phases.firstIndex(of: .activationFailed),
                recorder.phases.firstIndex(of: .stopCompleted)
            ].compactMap { $0 }
            XCTAssertTrue(
                terminalIndices.contains { $0 > startIndex },
                "Race path: .snapshotStarted must be followed by snapshot completion, activation failure, or stop completion"
            )
        }
    }

    @MainActor
    func testDevicePairApprovalAllowsLocallyOwnedDelegatedSession() throws {
        let ownerKey = P256.Signing.PrivateKey()
        let keyProvider = StubOwnerIdentityKeyProvider(privateKey: ownerKey)
        let household = Self.makeDelegatedHousehold(ownerPublicKey: keyProvider.publicKey)
        XCTAssertTrue(household.isDelegatedDevice)

        let runtime = HouseholdMachineJoinRuntime(
            keyProvider: keyProvider,
            session: URLSession(configuration: .ephemeral),
            nowProvider: { self.now }
        )
        let request = DevicePairRequestQueue.PendingRequest(
            envelope: DevicePairRequestEnvelope(
                requestId: "req-device-2",
                devicePublicKey: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
                deviceName: "Second iPhone",
                platform: "ios",
                ttlUnix: UInt64(now.addingTimeInterval(300).timeIntervalSince1970),
                receivedAt: now
            )
        )

        XCTAssertNoThrow(try runtime.makeDevicePairViewModel(for: request, household: household))
    }

    // MARK: - Fixtures

    /// Returns an `ActiveHouseholdState` whose endpoint resolves but
    /// refuses connection on TCP, so `HouseholdSnapshotBootstrapper`'s
    /// transport fails fast (within a few seconds across CI/local) and
    /// we can assert the failure-isolation contract without a live
    /// backend.
    private static func makeUnreachableHousehold() -> ActiveHouseholdState {
        let ownerKey = P256.Signing.PrivateKey()
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let householdKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: "hh_phaseTest",
            personId: "p_phaseTest",
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:hh_phaseTest",
            signature: Data(repeating: 0x11, count: 64)
        )
        return ActiveHouseholdState(
            householdId: "hh_phaseTest",
            householdName: "PhaseTest",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://127.0.0.1:1")!,
            ownerPersonId: "p_phaseTest",
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "phase-test-ref",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }

    private static func makeDelegatedHousehold(ownerPublicKey: Data) -> ActiveHouseholdState {
        let householdPublicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: "hh_delegated",
            personId: "p_delegated",
            personPublicKey: ownerPublicKey,
            displayName: "Owner iPhone",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:hh_delegated",
            signature: Data(repeating: 0x11, count: 64)
        )
        return ActiveHouseholdState(
            householdId: "hh_delegated",
            householdName: "Home",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: "p_delegated",
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "delegated-owner-ref",
            personCert: cert,
            devicePublicKey: ownerPublicKey,
            deviceKeyReference: "delegated-owner-ref",
            deviceCertCBOR: Data([0xA0]),
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }

    @MainActor
    private static func waitFor(
        timeout: TimeInterval,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func makePendingRequest(
        nonceByte: UInt8,
        ttl: UInt64
    ) -> JoinRequestQueue.PendingRequest {
        // `idempotencyKey` is derived from `householdId|machinePublicKey|nonce`,
        // so varying the nonce byte gives every fixture a stable, distinct
        // identity without depending on test-only API.
        let envelope = JoinRequestEnvelope(
            householdId: "hh_test",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: nonceByte, count: 32),
            rawHostname: "studio.local",
            rawPlatform: "macos",
            candidateAddress: "100.64.0.1",
            ttlUnix: ttl,
            challengeSignature: Data(repeating: 0x05, count: 64),
            transportOrigin: .bonjourShortcut,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return JoinRequestQueue.PendingRequest(envelope: envelope, cursor: 1)
    }
}

/// Captures the order in which `HouseholdMachineJoinRuntime` crosses
/// each `LifecyclePhase` boundary. The runtime hops the main actor only,
/// so a non-Sendable accumulator is safe — the recorder is never read
/// off the main actor during a test.
@MainActor
private final class LifecyclePhaseRecorder {
    private(set) var phases: [HouseholdMachineJoinRuntime.LifecyclePhase] = []

    func append(_ phase: HouseholdMachineJoinRuntime.LifecyclePhase) {
        phases.append(phase)
    }
}
