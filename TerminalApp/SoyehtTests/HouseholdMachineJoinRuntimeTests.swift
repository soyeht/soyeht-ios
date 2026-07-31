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

        let snapshotCursor: UInt64 = 37
        let snapshotBytes = try MachineJoinTestFixtures.signedHouseholdSnapshot(
            householdPrivateKey: householdKey,
            householdId: householdId,
            cursor: snapshotCursor
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
        await Self.waitFor(timeout: 5) {
            HouseholdRuntimeStubURLProtocol.captureURLs()
                .contains { $0.path == "/api/v1/household/owner-events" }
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
        let ownerEventsURL = try XCTUnwrap(
            HouseholdRuntimeStubURLProtocol.captureURLs()
                .first { $0.path == "/api/v1/household/owner-events" }
        )
        // Owner-events deliberately starts from zero even after snapshot
        // bootstrap. The snapshot cursor can already include a still-valid
        // device-pair request that is not represented in the snapshot body;
        // starting at the snapshot cursor would skip the approval card when
        // the owner iPhone foregrounds after the new iPhone requested pairing.
        // Expired historical requests are filtered by OwnerEventsLongPoll.
        let expectedSince = HouseholdCBOR.encode(.unsigned(0))
            .soyehtBase64URLEncodedString()
        XCTAssertEqual(ownerEventsURL.query, "since=\(expectedSince)")
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

    // MARK: - Roster activation (c2 publication/ordering)

    /// The roster step must run strictly between the snapshot and gossip: the
    /// snapshot is the atomic seed, and gossip must not start against a
    /// household whose roster state has not been established yet.
    ///
    /// Asserts the full seven-step activation window — including the
    /// gossip-cursor persist — as one contiguous run, so a step silently
    /// moving, vanishing or repeating fails here rather than passing on a
    /// truncated prefix.
    ///
    /// The window is anchored at `phase.snapshotStarted` rather than taken as
    /// `events.prefix(7)`: `activate` opens by calling `stop()` before it mints
    /// a token, so the raw trace legitimately begins with the
    /// `.stopRequested`/`.stopCompleted` pair (pinned independently by the
    /// existing boundary tests). Events after the window — `.ownerEventsStarted`
    /// and anything gossip emits later — are deliberately left unconstrained.
    /// Only `saveCursor` is instrumented; `loadCursor` is not, because
    /// `startGossip` reads the cursor before `.gossipStarted` is published.
    @MainActor
    func testRosterRunsBetweenSnapshotAndGossipInOrder() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshState: .degraded(reason: .transport, lastKnown: nil)
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.gossipStarted") }

        let expected = [
            "phase.snapshotStarted",
            "snapshot.bootstrap",
            "phase.snapshotCompleted",
            "cursor.save",
            "roster.bootstrap",
            "roster.refresh",
            "phase.gossipStarted",
        ]
        let events = trace.events
        guard let start = events.firstIndex(of: "phase.snapshotStarted") else {
            XCTFail("Activation never reached the snapshot step; observed: \(events)")
            return
        }
        let window = Array(events[start..<min(start + expected.count, events.count)])
        XCTAssertEqual(
            window, expected,
            "Activation window changed; observed: \(events)"
        )
        // Non-vacuity: a short or repeating trace must not satisfy the above.
        for label in expected {
            XCTAssertEqual(
                window.filter { $0 == label }.count, 1,
                "\(label) must appear exactly once in the activation window"
            )
        }
        runtime.stop()
    }

    /// `.degraded` is operational: activation survives, no `MachineJoinError` is
    /// raised, `.activationFailed` never fires, and gossip still starts.
    @MainActor
    func testRosterDegradedPreservesActivationAndStartsGossip() async throws {
        let trace = RosterTrace()
        let degraded = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_checkpoint_stale"),
            lastKnown: nil
        )
        let runtime = try Self.makeRosterRuntime(
            trace: trace, bootstrapState: .unknown, refreshState: degraded
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.gossipStarted") }

        XCTAssertEqual(runtime.rosterState, degraded)
        XCTAssertNil(runtime.lifecycleError, "degraded is not a MachineJoinError")
        XCTAssertFalse(trace.events.contains("phase.activationFailed"))
        XCTAssertTrue(trace.events.contains("phase.gossipStarted"))
        runtime.stop()
    }

    /// `.requiresRePairing` and `.tamperSuspected` must stay individually
    /// visible — neither may collapse into the other or into `lifecycleError`.
    @MainActor
    func testRosterRePairingAndTamperRemainDistinguishable() async throws {
        let rePairTrace = RosterTrace()
        let rePair = RosterCoordinatorState.requiresRePairing(retiredMId: "m_retired")
        let rePairRuntime = try Self.makeRosterRuntime(
            trace: rePairTrace, bootstrapState: .unknown, refreshState: rePair
        )
        rePairRuntime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { rePairTrace.events.contains("phase.gossipStarted") }

        let tamperTrace = RosterTrace()
        let tamper = RosterCoordinatorState.tamperSuspected(.anchorUnproven)
        let tamperRuntime = try Self.makeRosterRuntime(
            trace: tamperTrace, bootstrapState: .unknown, refreshState: tamper
        )
        tamperRuntime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { tamperTrace.events.contains("phase.gossipStarted") }

        XCTAssertEqual(rePairRuntime.rosterState, rePair)
        XCTAssertEqual(tamperRuntime.rosterState, tamper)
        XCTAssertNotEqual(rePairRuntime.rosterState, tamperRuntime.rosterState)
        XCTAssertNil(rePairRuntime.lifecycleError)
        XCTAssertNil(tamperRuntime.lifecycleError)
        rePairRuntime.stop()
        tamperRuntime.stop()
    }

    /// A token rotated mid-refresh must publish nothing from the stale
    /// activation and must not start gossip for it.
    @MainActor
    func testRosterTokenInvalidatedDuringRefreshPublishesNothingAndSkipsGossip() async throws {
        let trace = RosterTrace()
        let box = RuntimeBox()
        let runtime = try Self.makeRosterRuntime(
            trace: trace,
            bootstrapState: .degraded(reason: .transport, lastKnown: nil),
            refreshState: .requiresRePairing(retiredMId: "m_stale"),
            onRefresh: { await box.stopRuntime() }
        )
        box.runtime = runtime

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("roster.refresh") }
        await Self.waitFor(timeout: 2) { trace.events.contains("phase.stopCompleted") }

        XCTAssertEqual(
            runtime.rosterState, .unknown,
            "A stale activation must not publish its refresh result"
        )
        XCTAssertFalse(
            trace.events.contains("phase.gossipStarted"),
            "Gossip must not start for an activation whose token was rotated"
        )
    }

    /// Exactly one refresh per activation. The runtime never retries or probes;
    /// the coordinator is the only authority.
    @MainActor
    func testRosterRefreshCalledOncePerActivation() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshState: .tamperSuspected(.evidence(.signatureInvalid))
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.gossipStarted") }

        XCTAssertEqual(trace.events.filter { $0 == "roster.refresh" }.count, 1)
        XCTAssertEqual(trace.events.filter { $0 == "roster.bootstrap" }.count, 1)
        runtime.stop()
    }

    /// With no activator injected the roster step is skipped entirely and the
    /// state stays `.unknown`. `.unknown` means "nothing established", NOT
    /// "roster healthy" — the runtime must never publish a state it did not get
    /// from a coordinator.
    @MainActor
    func testNoRosterActivatorSkipsStepAndLeavesStateUnknown() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeRosterRuntime(
            trace: trace, bootstrapState: nil, refreshState: nil
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.gossipStarted") }

        XCTAssertEqual(runtime.rosterState, .unknown)
        XCTAssertFalse(trace.events.contains("roster.bootstrap"))
        XCTAssertFalse(trace.events.contains("roster.refresh"))
        XCTAssertTrue(trace.events.contains("phase.gossipStarted"))
        XCTAssertNil(runtime.lifecycleError)
        runtime.stop()
    }

    // MARK: - Foreground roster revalidation (warm-session currency)

    /// The audited limitation, stated as a test: activation publishes the
    /// roster, `stop()` clears it, but a foreground only ever forwarded to
    /// owner-events. A revocation the owner issued while this iPhone was
    /// backgrounded therefore stayed invisible for the whole warm session —
    /// the user had to log out and back in to see it.
    ///
    /// Revalidation must reuse the activation that is already live: same
    /// household, same identity, same route. Nothing here re-authenticates.
    @MainActor
    func testForegroundRevalidationSurfacesRevocationThatAppearedMidSession() async throws {
        let trace = RosterTrace()
        let healthy = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_checkpoint_stale"), lastKnown: nil
        )
        let revoked = RosterCoordinatorState.requiresRePairing(retiredMId: "m_retired_mid_session")
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace, bootstrapState: .unknown, refreshStates: [healthy, revoked]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }
        XCTAssertEqual(
            runtime.rosterState, healthy,
            "fixture must start from a state the banner stays silent on"
        )

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationPublished")
        }

        XCTAssertEqual(runtime.rosterState, revoked)
        XCTAssertNil(
            runtime.lifecycleError,
            "a roster condition is not an activation failure"
        )
        runtime.stop()
    }

    /// Same path, tamper instead of a proven revocation. The two must not
    /// collapse into one another on the foreground path any more than they do
    /// on the activation path.
    @MainActor
    func testForegroundRevalidationSurfacesTamperThatAppearedMidSession() async throws {
        let trace = RosterTrace()
        let healthy = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_checkpoint_stale"), lastKnown: nil
        )
        let tamper = RosterCoordinatorState.tamperSuspected(.evidence(.signatureInvalid))
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace, bootstrapState: .unknown, refreshStates: [healthy, tamper]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationPublished")
        }

        XCTAssertEqual(runtime.rosterState, tamper)
        XCTAssertNotEqual(runtime.rosterState, .requiresRePairing(retiredMId: "m_retired_mid_session"))
        runtime.stop()
    }

    /// Fail-closed must not mean stuck-closed. A condition the engine has
    /// since resolved has to clear on the same foreground path that raised it,
    /// or the banner becomes permanent and users learn to ignore it.
    @MainActor
    func testForegroundRevalidationClearsAResolvedCondition() async throws {
        let trace = RosterTrace()
        let tamper = RosterCoordinatorState.tamperSuspected(.anchorUnproven)
        let resolved = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_checkpoint_stale"), lastKnown: nil
        )
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace, bootstrapState: .unknown, refreshStates: [tamper, resolved]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }
        XCTAssertEqual(runtime.rosterState, tamper)

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationPublished")
        }

        XCTAssertEqual(runtime.rosterState, resolved)
        runtime.stop()
    }

    /// An attested "cannot answer" on the foreground path must arrive at the UI
    /// as the coordinator produced it — same reason, same `lastKnown` — rather
    /// than as a value the runtime rebuilt along the way.
    ///
    /// **What this test can and cannot prove, stated plainly.** It asserts
    /// whole-value equality of `RosterCoordinatorState`, so a runtime that
    /// changed the case or the reason fails here. It CANNOT vary `lastKnown`:
    /// `VerifiedRosterProjection` has no public initializer — the store and the
    /// verifier are its only producers, by design — and `SoyehtCore` is a
    /// SwiftPM target built without `-enable-testing`, so
    /// `@testable import SoyehtCore` does not resolve from this target
    /// ("module built without '-enable-testing'"). Publishing that initializer
    /// would let any caller mint a value whose type name asserts verification,
    /// which is exactly the containment this slice must not weaken to get a
    /// green check.
    ///
    /// So the `lastKnown` half is pinned by two other things, neither of which
    /// this test replaces:
    ///
    /// 1. `DevicePairApprovalPresentationTests`
    ///    `test_foregroundRevalidationPublishesTheCoordinatorStateWithoutRebuildingIt`
    ///    — the publish path assigns the coordinator's value as a whole and may
    ///    not destructure it. That holds for EVERY value, not just for one
    ///    fixture, so it is what actually refutes "rebuilds `.degraded` and
    ///    drops the projection".
    /// 2. `RosterEvidenceCoordinatorTests`
    ///    `engineUnavailableDegradesWithLastKnownAndLeavesStoreCurrent` and
    ///    `transportFailureDegradesWithLastKnownAndNextRefreshStillUsesIt` —
    ///    a real unavailable response carries the committed projection, the
    ///    latter over exactly the second-refresh-from-a-stable-binding path a
    ///    foreground revalidation takes.
    @MainActor
    func testForegroundRevalidationPublishesTheCoordinatorStateVerbatim() async throws {
        let trace = RosterTrace()
        let unavailable = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_owner_authority"), lastKnown: nil
        )
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [.tamperSuspected(.malformed), unavailable]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationPublished")
        }

        XCTAssertEqual(runtime.rosterState, unavailable)
        guard case .degraded(let reason, _) = runtime.rosterState else {
            XCTFail("expected the degraded value to survive the runtime hop")
            return
        }
        // Discriminating on the payload this target CAN vary: a runtime that
        // collapsed every unavailable outcome into one reason fails here.
        XCTAssertEqual(reason, .engine(outcome: "unavailable_owner_authority"))
        XCTAssertNotEqual(
            runtime.rosterState,
            .degraded(reason: .engine(outcome: "unavailable_checkpoint_stale"), lastKnown: nil)
        )
        XCTAssertNotEqual(runtime.rosterState, .degraded(reason: .transport, lastKnown: nil))
        runtime.stop()
    }

    /// Two foregrounds arriving while one round-trip is still open must
    /// produce one round-trip, not two. Held open by a gate so the second call
    /// provably lands mid-flight instead of relying on scheduling luck.
    @MainActor
    func testConcurrentForegroundsIssueASingleRosterRoundTrip() async throws {
        let trace = RosterTrace()
        let gate = RosterRefreshGate()
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [
                .degraded(reason: .transport, lastKnown: nil),
                .requiresRePairing(retiredMId: "m_single_flight"),
            ],
            // Call 0 is the activation's own refresh; call 1 is the first
            // foreground, which is the one held open.
            gateCall: 1,
            gate: gate
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) { trace.events.contains("roster.refresh.1") }
        runtime.enterForeground()

        XCTAssertEqual(
            trace.events.filter { $0 == "phase.rosterRevalidationStarted" }.count, 1,
            "the second foreground must not open a second round-trip"
        )
        XCTAssertEqual(
            trace.events.filter { $0 == "phase.rosterRevalidationSkipped" }.count, 1,
            "the dropped foreground must be reported, not silently swallowed"
        )

        await gate.release()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationPublished")
        }

        XCTAssertEqual(
            trace.events.filter { $0.hasPrefix("roster.refresh") }.count, 2,
            "exactly one activation refresh plus one foreground refresh"
        )
        XCTAssertEqual(runtime.rosterState, .requiresRePairing(retiredMId: "m_single_flight"))
        runtime.stop()
    }

    /// `stop()` must win against a revalidation that is already in flight. A
    /// late completion may neither resurrect the ex-household's roster on top
    /// of the `.unknown` teardown installed, nor leak it into the next
    /// activation.
    @MainActor
    func testStopBeatsAnInFlightForegroundRevalidation() async throws {
        let trace = RosterTrace()
        let gate = RosterRefreshGate()
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [
                .degraded(reason: .transport, lastKnown: nil),
                .tamperSuspected(.storeRefusedCandidate),
            ],
            gateCall: 1,
            gate: gate
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) { trace.events.contains("roster.refresh.1") }
        runtime.stop()
        await gate.release()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationDiscarded")
        }

        // Non-vacuity FIRST: with no revalidation there is no race, and every
        // assertion below would pass on a runtime that simply never re-checks
        // the roster. These three are what make the test discriminating.
        XCTAssertTrue(
            trace.events.contains("phase.rosterRevalidationStarted"),
            "a revalidation must actually have opened for there to be a race to win"
        )
        XCTAssertTrue(
            trace.events.contains("roster.refresh.1"),
            "the foreground round-trip must have reached the activator"
        )
        XCTAssertTrue(
            trace.events.contains("phase.rosterRevalidationDiscarded"),
            "the late completion must be reported as discarded, not silently dropped"
        )

        XCTAssertEqual(
            runtime.rosterState, .unknown,
            "a stale revalidation must not publish after teardown"
        )
        XCTAssertFalse(
            trace.events.contains("phase.rosterRevalidationPublished"),
            "the discarded revalidation must not also report a publish"
        )
    }

    /// Household switch is the same race with a live winner instead of a
    /// teardown: the new activation's roster must stand, and the previous
    /// household's in-flight result must never overwrite it.
    @MainActor
    func testHouseholdSwitchBeatsAnInFlightForegroundRevalidation() async throws {
        let trace = RosterTrace()
        let gate = RosterRefreshGate()
        let stale = RosterCoordinatorState.tamperSuspected(.anchorUnproven)
        let successor = RosterCoordinatorState.degraded(
            reason: .engine(outcome: "unavailable_clock_state"), lastKnown: nil
        )
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [
                .degraded(reason: .transport, lastKnown: nil),
                stale,
                successor,
            ],
            gateCall: 1,
            gate: gate
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }

        runtime.enterForeground()
        await Self.waitFor(timeout: 5) { trace.events.contains("roster.refresh.1") }

        // A different household takes over while the previous household's
        // revalidation is still open.
        runtime.activate(Self.makeUnreachableHousehold(householdId: "hh_successor"))
        await Self.waitFor(timeout: 5) { trace.events.contains("roster.refresh.2") }
        await gate.release()
        await Self.waitFor(timeout: 5) {
            trace.events.contains("phase.rosterRevalidationDiscarded")
        }

        // Same non-vacuity discipline as the stop race: the successor result
        // must be reached with the predecessor's revalidation still open and
        // then explicitly discarded, not by there never having been one.
        XCTAssertTrue(
            trace.events.contains("phase.rosterRevalidationStarted"),
            "a revalidation must actually have opened for there to be a race to win"
        )
        XCTAssertTrue(
            trace.events.contains("phase.rosterRevalidationDiscarded"),
            "the predecessor's late completion must be reported as discarded"
        )

        XCTAssertEqual(runtime.rosterState, successor)
        XCTAssertNotEqual(
            runtime.rosterState, stale,
            "the previous household's roster must not survive the switch"
        )
        runtime.stop()
    }

    /// Adding roster work to the foreground path must not steal, duplicate, or
    /// reorder the owner-events wake-up the operator is actually waiting on.
    @MainActor
    func testEnterForegroundForwardsToOwnerEventsExactlyOncePerCall() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [
                .degraded(reason: .transport, lastKnown: nil),
                .degraded(reason: .transport, lastKnown: nil),
            ]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }
        XCTAssertEqual(
            trace.events.filter { $0 == "phase.ownerEventsForegrounded" }.count, 0,
            "activation starts owner-events through its own phase, not the foreground one"
        )

        runtime.enterForeground()
        XCTAssertEqual(
            trace.events.filter { $0 == "phase.ownerEventsForegrounded" }.count, 1
        )

        runtime.enterForeground()
        XCTAssertEqual(
            trace.events.filter { $0 == "phase.ownerEventsForegrounded" }.count, 2,
            "each foreground forwards once — no coalescing, no double-forward"
        )
        runtime.stop()
    }

    /// Fail-closed in the other direction: with no live activation there is no
    /// validated household, identity or route to revalidate against, so a
    /// foreground must issue no request and publish nothing. `stop()` clearing
    /// `rosterState` is a side effect; this is the rule.
    @MainActor
    func testForegroundAfterStopNeitherFetchesNorPublishes() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [
                .degraded(reason: .transport, lastKnown: nil),
                .requiresRePairing(retiredMId: "m_must_never_appear"),
            ]
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }
        runtime.stop()

        let refreshesBefore = trace.events.filter { $0.hasPrefix("roster.refresh") }.count
        runtime.enterForeground()
        // Long enough for a request to have been issued and returned if the
        // gate had failed open.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            trace.events.filter { $0.hasPrefix("roster.refresh") }.count, refreshesBefore,
            "a foreground on an inactive identity must issue no roster request"
        )
        XCTAssertEqual(runtime.rosterState, .unknown)
        XCTAssertTrue(trace.events.contains("phase.rosterRevalidationSkipped"))
        XCTAssertFalse(trace.events.contains("phase.rosterRevalidationStarted"))
        XCTAssertFalse(
            trace.events.contains("phase.ownerEventsForegrounded"),
            "teardown released the coordinator; there is nothing to foreground"
        )
    }

    /// A runtime that never activated is the cold-launch case: same rule, and
    /// it must not crash or fabricate an activator.
    @MainActor
    func testForegroundBeforeAnyActivationNeitherFetchesNorPublishes() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeForegroundRosterRuntime(
            trace: trace,
            bootstrapState: .unknown,
            refreshStates: [.requiresRePairing(retiredMId: "m_must_never_appear")]
        )

        runtime.enterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(trace.events.filter { $0.hasPrefix("roster.refresh") }.isEmpty)
        XCTAssertEqual(runtime.rosterState, .unknown)
        XCTAssertEqual(trace.events, ["phase.rosterRevalidationSkipped"])
    }

    /// No activator wired (production without a resolvable roster route) means
    /// there is nothing to revalidate. The foreground must stay silent rather
    /// than inventing a coordinator or publishing a state nobody produced.
    @MainActor
    func testForegroundWithoutARosterActivatorSkipsWithoutPublishing() async throws {
        let trace = RosterTrace()
        let runtime = try Self.makeRosterRuntime(
            trace: trace, bootstrapState: nil, refreshState: nil
        )

        runtime.activate(Self.makeUnreachableHousehold())
        await Self.waitFor(timeout: 5) { trace.events.contains("phase.ownerEventsStarted") }
        runtime.enterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(runtime.rosterState, .unknown)
        XCTAssertFalse(trace.events.contains("roster.refresh"))
        XCTAssertTrue(trace.events.contains("phase.rosterRevalidationSkipped"))
        XCTAssertFalse(trace.events.contains("phase.rosterRevalidationStarted"))
        XCTAssertEqual(
            trace.events.filter { $0 == "phase.ownerEventsForegrounded" }.count, 1,
            "owner-events still wakes up on a household with no roster route"
        )
        runtime.stop()
    }

    // MARK: - Fixtures

    /// Builds a runtime whose snapshot step is stubbed (so activation reaches
    /// the roster step without a signed corpus) and whose roster activator is
    /// injected. Passing `nil` states omits the activator entirely.
    @MainActor
    private static func makeRosterRuntime(
        trace: RosterTrace,
        bootstrapState: RosterCoordinatorState?,
        refreshState: RosterCoordinatorState?,
        onRefresh: (@Sendable () async -> Void)? = nil
    ) throws -> HouseholdMachineJoinRuntime {
        let identity = FakeOwnerIdentity(
            personId: "p_phaseTest",
            publicKey: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            keyReference: "phase-test-ref"
        )
        let snapshotResult = HouseholdSnapshotBootstrapResult(
            householdId: "hh_phaseTest",
            cursor: 7,
            headEventHash: Data(repeating: 0x0E, count: 32),
            issuedAt: Date(timeIntervalSince1970: 1),
            insertedRevocationCount: 0,
            memberCount: 1,
            skippedRevokedMachineCount: 0
        )
        let rosterFactory: (
            @MainActor (ActiveHouseholdState, HouseholdPoPSigner) -> any RosterEvidenceActivating
        )?
        if let bootstrapState, let refreshState {
            let activator = FakeRosterActivating(
                trace: trace,
                bootstrapState: bootstrapState,
                refreshState: refreshState,
                onRefresh: onRefresh
            )
            rosterFactory = { _, _ in activator }
        } else {
            rosterFactory = nil
        }
        return HouseholdMachineJoinRuntime(
            keyProvider: FakeOwnerIdentityProvider(identity: identity),
            crlStore: try CRLStore(storage: RosterTraceStorage(), account: "test.roster.crl"),
            gossipCursorStore: NoopGossipCursorStore(trace: trace),
            rosterActivatingFactory: rosterFactory,
            snapshotBootstrappingFactory: { _, _, _ in
                FakeSnapshotBootstrapping(trace: trace, result: snapshotResult)
            },
            phaseObserver: { phase in trace.record("phase.\(phase)") }
        )
    }

    /// Same as `makeRosterRuntime`, but the injected activator answers from a
    /// scripted sequence of refresh results instead of one fixed state — which
    /// is what lets a mid-session change (a revocation appearing, a condition
    /// clearing) be modelled without a network. `gateCall` holds that one
    /// round-trip open until the test releases it, so races are exercised
    /// against a provably in-flight refresh rather than scheduling luck.
    @MainActor
    private static func makeForegroundRosterRuntime(
        trace: RosterTrace,
        bootstrapState: RosterCoordinatorState,
        refreshStates: [RosterCoordinatorState],
        gateCall: Int? = nil,
        gate: RosterRefreshGate? = nil
    ) throws -> HouseholdMachineJoinRuntime {
        let identity = FakeOwnerIdentity(
            personId: "p_phaseTest",
            publicKey: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            keyReference: "phase-test-ref"
        )
        let snapshotResult = HouseholdSnapshotBootstrapResult(
            householdId: "hh_phaseTest",
            cursor: 7,
            headEventHash: Data(repeating: 0x0E, count: 32),
            issuedAt: Date(timeIntervalSince1970: 1),
            insertedRevocationCount: 0,
            memberCount: 1,
            skippedRevokedMachineCount: 0
        )
        let activator = ScriptedRosterActivating(
            trace: trace,
            bootstrapState: bootstrapState,
            refreshStates: refreshStates,
            gateCall: gateCall,
            gate: gate
        )
        return HouseholdMachineJoinRuntime(
            keyProvider: FakeOwnerIdentityProvider(identity: identity),
            crlStore: try CRLStore(storage: RosterTraceStorage(), account: "test.roster.crl.foreground"),
            gossipCursorStore: NoopGossipCursorStore(),
            rosterActivatingFactory: { _, _ in activator },
            snapshotBootstrappingFactory: { _, _, _ in
                FakeSnapshotBootstrapping(trace: trace, result: snapshotResult)
            },
            phaseObserver: { phase in trace.record("phase.\(phase)") }
        )
    }

    /// Returns an `ActiveHouseholdState` whose endpoint resolves but
    /// refuses connection on TCP, so `HouseholdSnapshotBootstrapper`'s
    /// transport fails fast (within a few seconds across CI/local) and
    /// we can assert the failure-isolation contract without a live
    /// backend.
    ///
    /// `householdId` is parameterised so a switch to a *different* household
    /// can be modelled; every existing caller keeps the original fixture id.
    private static func makeUnreachableHousehold(
        householdId: String = "hh_phaseTest"
    ) -> ActiveHouseholdState {
        let ownerKey = P256.Signing.PrivateKey()
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let householdKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: householdId,
            personId: "p_phaseTest",
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

// MARK: - Roster activation fakes

/// Shared, ordered trace so roster calls and lifecycle phases can be asserted
/// against each other in a single sequence.
private final class RosterTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Holds the runtime so an injected refresh hook can rotate the activation
/// token mid-flight without a capture cycle at construction time.
@MainActor
private final class RuntimeBox {
    weak var runtime: HouseholdMachineJoinRuntime?

    func stopRuntime() {
        runtime?.stop()
    }
}

private final class FakeRosterActivating: RosterEvidenceActivating, @unchecked Sendable {
    private let trace: RosterTrace
    private let bootstrapState: RosterCoordinatorState
    private let refreshState: RosterCoordinatorState
    private let onRefresh: (@Sendable () async -> Void)?

    init(
        trace: RosterTrace,
        bootstrapState: RosterCoordinatorState,
        refreshState: RosterCoordinatorState,
        onRefresh: (@Sendable () async -> Void)? = nil
    ) {
        self.trace = trace
        self.bootstrapState = bootstrapState
        self.refreshState = refreshState
        self.onRefresh = onRefresh
    }

    func bootstrap() async -> RosterCoordinatorState {
        trace.record("roster.bootstrap")
        return bootstrapState
    }

    func refresh() async -> RosterCoordinatorState {
        trace.record("roster.refresh")
        await onRefresh?()
        return refreshState
    }
}

/// Holds one specific roster round-trip open until the test releases it.
///
/// Continuation-based rather than a polling sleep on purpose: `stop()` and a
/// household switch both cancel the revalidation Task, and a `Task.sleep` loop
/// would either spin hot or return early under cancellation — which would let
/// the very race being tested resolve itself by accident.
private actor RosterRefreshGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Roster activator answering from a scripted sequence: call *n* returns
/// `refreshStates[n]`, and the last entry repeats so an unexpected extra
/// round-trip shows up as a call-count change rather than an index crash.
///
/// The trace entry is recorded *before* the gate is awaited, so a test that
/// waits for `roster.refresh.<n>` knows it is observing a refresh that is still
/// in flight.
private final class ScriptedRosterActivating: RosterEvidenceActivating, @unchecked Sendable {
    private let trace: RosterTrace
    private let bootstrapState: RosterCoordinatorState
    private let refreshStates: [RosterCoordinatorState]
    private let gateCall: Int?
    private let gate: RosterRefreshGate?
    private let lock = NSLock()
    private var refreshCalls = 0

    init(
        trace: RosterTrace,
        bootstrapState: RosterCoordinatorState,
        refreshStates: [RosterCoordinatorState],
        gateCall: Int? = nil,
        gate: RosterRefreshGate? = nil
    ) {
        precondition(!refreshStates.isEmpty, "a scripted activator needs at least one refresh state")
        self.trace = trace
        self.bootstrapState = bootstrapState
        self.refreshStates = refreshStates
        self.gateCall = gateCall
        self.gate = gate
    }

    func bootstrap() async -> RosterCoordinatorState {
        trace.record("roster.bootstrap")
        return bootstrapState
    }

    func refresh() async -> RosterCoordinatorState {
        lock.lock()
        let call = refreshCalls
        refreshCalls += 1
        lock.unlock()
        trace.record("roster.refresh.\(call)")
        if let gate, gateCall == call {
            await gate.wait()
        }
        return refreshStates[min(call, refreshStates.count - 1)]
    }
}

private final class FakeSnapshotBootstrapping: HouseholdSnapshotBootstrapping, @unchecked Sendable {
    private let trace: RosterTrace
    private let result: HouseholdSnapshotBootstrapResult

    init(trace: RosterTrace, result: HouseholdSnapshotBootstrapResult) {
        self.trace = trace
        self.result = result
    }

    func bootstrap() async throws -> HouseholdSnapshotBootstrapResult {
        trace.record("snapshot.bootstrap")
        return result
    }
}

private struct FakeOwnerIdentity: OwnerIdentitySigning {
    let personId: String
    let publicKey: Data
    let keyReference: String

    func sign(_ payload: Data) throws -> Data {
        Data(repeating: 0x01, count: 64)
    }
}

private struct FakeOwnerIdentityProvider: OwnerIdentityKeyCreating {
    let identity: FakeOwnerIdentity

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning { identity }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        identity
    }

    func loadOwnerIdentity(
        keyReference: String,
        publicKey: Data,
        personId: String
    ) throws -> any OwnerIdentitySigning {
        identity
    }
}

/// In-memory secure storage so the CRL store never touches the real Keychain.
private final class RosterTraceStorage: HouseholdSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ data: Data, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[account] = data
        return true
    }

    func load(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

/// Keeps gossip-cursor writes out of UserDefaults during tests, and — when a
/// trace is supplied — records the persist so the cursor save can be pinned in
/// the activation sequence rather than assumed.
private final class NoopGossipCursorStore: HouseholdGossipCursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: UInt64] = [:]
    private let trace: RosterTrace?

    init(trace: RosterTrace? = nil) {
        self.trace = trace
    }

    func loadCursor(for householdId: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return cursors[householdId]
    }

    func saveCursor(_ cursor: UInt64, for householdId: String) {
        lock.lock()
        cursors[householdId] = cursor
        lock.unlock()
        trace?.record("cursor.save")
    }

    func clearCursor(for householdId: String) {
        lock.lock(); defer { lock.unlock() }
        cursors.removeValue(forKey: householdId)
    }
}
