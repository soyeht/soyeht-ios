import CryptoKit
import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import XCTest

@testable import Soyeht

final class ClawSiteRelayStreamOpenerTests: XCTestCase {
    func testFirstExchangeUsesTheTargetConnectPersistentAlreadyOpened() async throws {
        let native = FakeClawSiteNativeAPI(session: FakeClawSiteNativeSession())
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        let stream = try await opener.openClawSiteStream()
        try await stream.close()

        XCTAssertEqual(native.connectPersistentCallCount, 1)
        // The first exchange must NOT call openNextTarget: connectPersistent
        // already negotiated the first target as part of dialing (see the
        // Rust doc). Calling it again here would be the exact out-of-turn
        // OpenPersistent that kills the whole connection.
        XCTAssertEqual(native.lastSession?.openNextTargetCallCount, 0)
        XCTAssertEqual(native.lastSession?.closeCallCount, 1)
    }

    func testSecondExchangeReusesTheConnectionViaOpenNextTarget() async throws {
        let native = FakeClawSiteNativeAPI(session: FakeClawSiteNativeSession())
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        try await opener.openClawSiteStream().close()
        try await opener.openClawSiteStream().close()

        // One dial for both exchanges — this is the whole point of
        // `OpenPersistent`: a second HTTP request is not a second relay dial.
        XCTAssertEqual(native.connectPersistentCallCount, 1)
        XCTAssertEqual(native.lastSession?.openNextTargetCallCount, 1)
        XCTAssertEqual(native.lastSession?.closeCallCount, 2)
    }

    func testRedialsOnlyAfterTheSessionFails() async throws {
        let firstSession = FakeClawSiteNativeSession()
        let secondSession = FakeClawSiteNativeSession()
        let native = FakeClawSiteNativeAPI(sessions: [firstSession, secondSession])
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        // First exchange's close() fails — the session must be dropped, not
        // just this one target, because the real server does not
        // distinguish "this target broke" from "this connection broke."
        firstSession.closeError = SentinelError.boom
        let first = try await opener.openClawSiteStream()
        await XCTAssertThrowsErrorAsync(try await first.close())

        // Second exchange must redial, not reuse the broken session.
        let second = try await opener.openClawSiteStream()
        try await second.close()

        XCTAssertEqual(native.connectPersistentCallCount, 2)
        XCTAssertEqual(secondSession.openNextTargetCallCount, 0, "fresh dial opened its own first target")
    }

    func testRedialAfterAnUnavailableSignalReusesTheIdenticalOfferAndCredentialBytes() async throws {
        // Proves the REDIAL half of "same offer+credential, no second
        // claim" at the byte level — the claim-count half (that no NEW
        // claim happens anywhere upstream) is proven separately in
        // ClawShareOpenRouterTests, since this opener has no reference to
        // a claim submitter at all to begin with.
        let firstSession = FakeClawSiteNativeSession()
        let secondSession = FakeClawSiteNativeSession()
        let native = FakeClawSiteNativeAPI(sessions: [firstSession, secondSession])
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        // First exchange: freshly dialed, target already open — no
        // `openNextTarget` call yet.
        try await opener.openClawSiteStream().close()

        // Second exchange reuses the session via `openNextTarget`, which is
        // where the engine's router reason would surface on a subsequent
        // target open. `openNextTarget` is awaited INSIDE
        // `openClawSiteStream` itself (not deferred to the returned
        // stream), so the failure surfaces right here.
        firstSession.openNextTargetError = RelayStreamGuestError.AuthRejected(
            "target service unavailable: relay-stream-share-app-unavailable"
        )
        await XCTAssertThrowsErrorAsync(try await opener.openClawSiteStream())

        // Third exchange: session was dropped by the failure, so this
        // redials — same offer/credential, not a second claim.
        let recovered = try await opener.openClawSiteStream()
        try await recovered.close()

        XCTAssertEqual(native.connectPersistentCallCount, 2, "exactly one initial dial + one redial")
        XCTAssertEqual(native.connectPersistentCalls.count, 2)
        XCTAssertEqual(
            native.connectPersistentCalls[0].offerCbor, native.connectPersistentCalls[1].offerCbor,
            "redial must send the SAME offer bytes, not a freshly-claimed one"
        )
        XCTAssertEqual(
            native.connectPersistentCalls[0].expectedOwnerPub, native.connectPersistentCalls[1].expectedOwnerPub
        )
        XCTAssertEqual(
            native.connectPersistentCalls[0].expectedGuestPub, native.connectPersistentCalls[1].expectedGuestPub
        )
    }

    func testConcurrentExchangesSerializeOntoOneLiveTarget() async throws {
        // The reentrancy hazard this pins: an `actor` alone is not enough —
        // `openClawSiteStream()` awaits real I/O (`openNextTarget`), and a
        // second caller's invocation can run during that suspension. Without
        // an explicit slot, both calls could race `openNextTarget()` onto the
        // same connection, which the real server treats as a framing
        // violation that kills the whole thing.
        let session = FakeClawSiteNativeSession()
        let native = FakeClawSiteNativeAPI(session: session)
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        // Prime the connection so both exchanges under test go through
        // `openNextTarget()`, the operation being raced.
        try await opener.openClawSiteStream().close()
        XCTAssertEqual(session.openNextTargetCallCount, 0)

        session.gateNextOpenNextTarget()
        async let first = opener.openClawSiteStream()

        // Give the first call every chance to reach (and block inside)
        // openNextTarget before the second is even issued.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.openNextTargetEntryCount, 1, "first call should be inside openNextTarget")
        XCTAssertEqual(session.openNextTargetCallCount, 0, "first call must not have completed yet")

        async let second = opener.openClawSiteStream()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            session.openNextTargetEntryCount, 1,
            "second call must not enter openNextTarget while the first is still open"
        )

        session.releaseGatedOpenNextTarget()
        let firstStream = try await first
        try await firstStream.close()

        let secondStream = try await second
        try await secondStream.close()

        XCTAssertEqual(session.openNextTargetCallCount, 2)
        XCTAssertEqual(native.connectPersistentCallCount, 1, "still one connection for all three exchanges")
    }

    func testCancelledWaiterReturnsPromptlyAndDoesNotOrphanATarget() async throws {
        // The bug this pins: an ordinary `[CheckedContinuation<Void, Never>]`
        // queue has no way to remove a cancelled waiter — it sits queued
        // until naturally dequeued, then resumes into opening a target
        // nobody is reading from, AND makes the caller behind it (C) wait
        // for that orphan to run first. `acquireTargetSlot`'s
        // `withTaskCancellationHandler` must remove B immediately instead.
        let session = FakeClawSiteNativeSession()
        let native = FakeClawSiteNativeAPI(session: session)
        let opener = try Self.makeOpener(client: RelayStreamGuestDataPlaneClient(native: native))

        // Prime the connection so the exchanges under test go through
        // openNextTarget, the operation whose queueing is being raced.
        try await opener.openClawSiteStream().close()
        XCTAssertEqual(session.openNextTargetCallCount, 0)

        // A holds the slot with its own openNextTarget gated open, so it
        // does not finish until explicitly released below.
        session.gateNextOpenNextTarget()
        async let aStream = opener.openClawSiteStream()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.openNextTargetEntryCount, 1, "A should already be inside openNextTarget")

        // B queues behind A — the slot is still held — then gets cancelled
        // before A ever releases it.
        let bTask = Task { try await opener.openClawSiteStream() }
        try await Task.sleep(for: .milliseconds(50))
        bTask.cancel()

        let cancelObserved = ContinuousClock.now
        do {
            _ = try await bTask.value
            XCTFail("expected B's cancellation to surface as an error")
        } catch {
            // Any error is acceptable — promptness is the property under
            // test, not which error type propagates.
        }
        let cancelToReturn = ContinuousClock.now - cancelObserved
        XCTAssertLessThan(
            cancelToReturn, .milliseconds(500),
            "a cancelled waiter must return promptly, not wait for A to finish first"
        )

        // A finally finishes and closes its target.
        session.releaseGatedOpenNextTarget()
        let aResult = try await aStream
        try await aResult.close()

        // C opens normally right after — proves B's cancellation left no
        // orphaned target open and did not leave the slot stuck.
        let cResult = try await opener.openClawSiteStream()
        try await cResult.close()

        XCTAssertEqual(
            session.openNextTargetCallCount, 2,
            "only A and C ever actually completed openNextTarget — B's cancelled attempt must not count"
        )
        XCTAssertEqual(native.connectPersistentCallCount, 1, "still just the one original dial throughout")
    }

    func testCancellationRightAtHandoffReleasesTheSlotBeforeOpeningAnyTarget() async throws {
        // The narrow race `testCancelledWaiterReturnsPromptlyAndDoesNotOrphanATarget`
        // does NOT cover: there, B is cancelled while still QUEUED, well
        // before A releases. Here B is cancelled at the exact instant its
        // `acquireTargetSlot()` continuation has ALREADY resumed
        // successfully — `releaseTargetSlot`'s synchronous resume can win
        // that race against the `onCancel`-spawned cancellation Task (an
        // async hop), so B would otherwise proceed to open a real target
        // nobody reads from.
        //
        // Every step of the interleaving is pinned by an explicit signal,
        // not a sleep: A's entry into its gated `openNextTarget`, B's
        // enqueue, and B's pause at the post-handoff seam are all awaited
        // deterministically, so this test cannot be flaky under CI load and
        // cannot race a real fix into looking broken (or a real bug into
        // looking fine).
        let session = FakeClawSiteNativeSession()
        let native = FakeClawSiteNativeAPI(session: session)
        let aEnteredGate = OneShotSignal()
        let bEnqueued = OneShotSignal()
        let seamReached = OneShotSignal()
        let seamRelease = OneShotSignal()
        session.onGatedOpenNextTargetEntry = {
            aEnteredGate.signal()
        }
        let opener = try Self.makeOpener(
            client: RelayStreamGuestDataPlaneClient(native: native),
            postHandoffCancellationSeam: {
                seamReached.signal()
                await seamRelease.wait()
            },
            targetSlotWaiterEnqueuedSeam: {
                bEnqueued.signal()
            }
        )

        // Prime the connection so the exchanges under test go through
        // openNextTarget, same as the sibling test above.
        try await opener.openClawSiteStream().close()
        XCTAssertEqual(session.openNextTargetCallCount, 0)

        // A holds the slot with its own openNextTarget gated open. Awaited
        // via `aEnteredGate`, fired the instant A is genuinely blocked
        // inside the gate -- not inferred from a sleep plus a count check.
        session.gateNextOpenNextTarget()
        async let aStream = opener.openClawSiteStream()
        await aEnteredGate.wait()
        XCTAssertEqual(session.openNextTargetEntryCount, 1, "A should already be inside openNextTarget")

        // B queues behind A. Awaited via `bEnqueued`, fired synchronously,
        // on the actor, the instant B's continuation is actually registered
        // in `targetSlotWaiters` -- the earliest possible point at which B
        // is a real, resumable queued waiter.
        let bTask = Task { try await opener.openClawSiteStream() }
        await bEnqueued.wait()

        // A releases, handing the slot DIRECTLY to B. B's acquireTargetSlot
        // resumes successfully and pauses at the seam -- again awaited
        // deterministically.
        session.releaseGatedOpenNextTarget()
        let aResult = try await aStream
        try await aResult.close()
        await seamReached.wait()

        // B is cancelled RIGHT NOW: already past the handoff, still paused
        // at the seam, before it has touched `activeSession`/`openNextTarget`
        // at all.
        bTask.cancel()
        seamRelease.signal()

        do {
            let bStream = try await withTestTimeout(.seconds(2)) { try await bTask.value }
            // Unexpected success means the fix under test regressed: B
            // resumed holding the slot instead of throwing. Close it before
            // failing -- otherwise the slot never comes back and C below
            // hangs forever instead of this assertion failing promptly.
            try? await bStream.close()
            XCTFail("expected B's post-handoff cancellation to surface as an error")
        } catch is CancellationError {
            // Expected.
        } catch is TestTimeoutError {
            XCTFail("B's post-handoff cancellation must resolve promptly, not hang")
        }

        // B must have made zero progress toward opening a target: only A's
        // one completed open (and zero further entries) so far.
        XCTAssertEqual(session.openNextTargetEntryCount, 1, "B must never even enter openNextTarget")
        XCTAssertEqual(session.openNextTargetCallCount, 1, "B must never complete an open")

        // C then progresses normally -- proof the slot was actually handed
        // back, not left stuck on B's abandoned claim. Bounded too: if B's
        // failure mode above ever changes shape, C must not silently hang
        // this test instead of failing it.
        let cResult = try await withTestTimeout(.seconds(2)) { try await opener.openClawSiteStream() }
        try await withTestTimeout(.seconds(2)) { try await cResult.close() }

        XCTAssertEqual(session.openNextTargetEntryCount, 2, "only A and C ever entered openNextTarget")
        XCTAssertEqual(session.openNextTargetCallCount, 2, "only A and C ever completed an open")
        XCTAssertEqual(native.connectPersistentCallCount, 1, "still just the one original dial throughout")
    }

    private static func makeOpener(
        client: RelayStreamGuestDataPlaneClient,
        postHandoffCancellationSeam: (@Sendable () async -> Void)? = nil,
        targetSlotWaiterEnqueuedSeam: (@Sendable () -> Void)? = nil
    ) throws -> ClawSiteRelayStreamOpener {
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let identity = FixedClawSiteGuestIdentity(
            publicKeyData: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x33, count: 32)
            ).publicKey.compressedRepresentation,
            signature: Data(repeating: 0xA5, count: 64)
        )
        let credential = GuestCredential(
            householdId: "hh-alpha",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw-alpha",
            guestDevicePublicKey: identity.publicKeyData,
            slotId: Data(repeating: 0x22, count: 16),
            issuedAt: 1_800_000_000,
            expiresAt: 1_800_000_600,
            ownerSignature: Data(repeating: 0x77, count: 64)
        )
        // A real signature, not a placeholder: `ClawSiteRelayStreamOpener`
        // calls `offer.verifyRelayStreamGuest` on every (re)dial, which
        // cryptographically verifies this against `ownerKey` — a dummy byte
        // pattern is correctly rejected there, not silently accepted.
        let payload = RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x42, count: 16),
            clawId: credential.clawId,
            slotId: credential.slotId,
            guestDevicePublicKey: credential.guestDevicePublicKey,
            resource: .clawSite,
            expectedPath: .relayStream,
            relayEndpoint: "relay-stream://198.51.100.10:49152",
            clawStaticPublicKey: Data(repeating: 0x44, count: 32),
            notAfter: credential.expiresAt
        )
        let offer = RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: credential.ownerPublicKey,
            signature: try ownerKey.signature(for: payload.canonicalBytes()).rawRepresentation
        )
        return ClawSiteRelayStreamOpener(
            offer: offer,
            credential: credential,
            guestIdentity: identity,
            client: client,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000123")! },
            postHandoffCancellationSeam: postHandoffCancellationSeam,
            targetSlotWaiterEnqueuedSeam: targetSlotWaiterEnqueuedSeam
        )
    }
}

private enum SentinelError: Error, Equatable {
    case boom
}

private struct TestTimeoutError: Error {}

/// A true race between two unstructured `Task`s, decided by whichever
/// reports first through a lock-guarded one-shot outcome. Deliberately NOT
/// `withThrowingTaskGroup`: that API's scope exit awaits every child task
/// even after `cancelAll()`, so if the losing child is stuck in a
/// non-cooperative hang (ignores cancellation, e.g. awaiting a `Task.value`
/// that itself never resolves), the group -- and thus the whole helper --
/// would hang too, silently breaking the one guarantee callers rely on.
/// Here, once the outcome is decided, `awaitDecision()` returns
/// IMMEDIATELY; the loser is cancelled but never awaited by this function.
private final class TestRaceOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var decided = false
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func decide(_ result: Result<T, Error>) {
        lock.lock()
        guard !decided else {
            lock.unlock()
            return
        }
        decided = true
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
    }

    func awaitDecision() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Races `operation` against a bound: if `operation` does not finish
/// first, throws `TestTimeoutError` instead of waiting forever. For
/// proving a mutation is caught RED within a bound instead of hanging the
/// whole suite -- a regression that removes a cancellation check can
/// otherwise turn "the test correctly fails" into "the test process never
/// returns." Returns/throws as soon as the bound elapses even if
/// `operation` keeps running: cancellation is REQUESTED on it, not
/// guaranteed to take effect promptly if it ignores cancellation
/// (non-cooperative), so it may still be executing in the background;
/// callers that need the loser's side effects cleaned up must do so
/// themselves (this helper only decides which result to report).
private func withTestTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let outcome = TestRaceOutcome<T>()
    let operationTask = Task {
        do {
            outcome.decide(.success(try await operation()))
        } catch {
            outcome.decide(.failure(error))
        }
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: duration)
        outcome.decide(.failure(TestTimeoutError()))
    }
    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }
    return try await outcome.awaitDecision()
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        // Any error is acceptable — the point under test is that it propagates.
    }
}

/// A one-shot, awaitable signal: `wait()` suspends until `signal()` is
/// called, from either order. Used to pin a specific interleaving
/// deterministically (e.g. "code is now paused exactly here") instead of
/// inferring it from a sleep.
private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.fired {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }
}

private struct FixedClawSiteGuestIdentity: ClawShareGuestIdentity {
    let publicKeyData: Data
    let signature: Data

    func sign(_ data: Data) throws -> Data {
        signature
    }
}

/// Records calls and can gate `openNextTarget` on an external release, to
/// pin the serialization test's interleaving deterministically instead of
/// relying on timing alone for the assertion that matters.
private final class FakeClawSiteNativeSession: RelayStreamGuestSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var openNextTargetCallCount = 0
    private(set) var openNextTargetEntryCount = 0
    private(set) var closeCallCount = 0
    var closeError: Error?
    var openNextTargetError: Error?

    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false

    /// Fires the instant a gated `openNextTarget()` call is ABOUT to
    /// suspend on the gate — deterministic proof "this call is now inside
    /// and blocked here," so a test can `await` it instead of sleeping and
    /// polling `openNextTargetEntryCount`.
    var onGatedOpenNextTargetEntry: (@Sendable () -> Void)?

    func gateNextOpenNextTarget() {
        lock.lock()
        gated = true
        lock.unlock()
    }

    func releaseGatedOpenNextTarget() {
        lock.lock()
        let continuation = gate
        gate = nil
        lock.unlock()
        continuation?.resume()
    }

    func metadata() async -> RelayStreamGuestSessionMetadata {
        RelayStreamGuestSessionMetadata(meshIpv4: nil, meshIpv6: "fd00::10", mtu: 1_280, sessionId: "s")
    }

    func readFrame() async throws -> RelayStreamGuestFrameRecord {
        RelayStreamGuestFrameRecord(kind: .close, data: Data(), number: 0, text: "")
    }

    func sendClose() async throws {
        lock.lock()
        closeCallCount += 1
        let error = closeError
        lock.unlock()
        if let error { throw error }
    }

    func sendData(data: Data) async throws {}

    func sendResize(cols: UInt16, rows: UInt16) async throws {}

    func openNextTarget() async throws {
        lock.lock()
        openNextTargetEntryCount += 1
        let shouldWait = gated
        gated = false
        let error = openNextTargetError
        lock.unlock()
        if shouldWait {
            // `gate` MUST be stored under the lock, and the entry signal
            // MUST fire only AFTER that store, not before: firing first
            // would let an observer call `releaseGatedOpenNextTarget()`
            // while `gate` is still nil (a lost wakeup -- the release finds
            // nothing to resume, and this call hangs forever once the real
            // continuation installs afterward with nobody left to release
            // it). Storing under the same lock `releaseGatedOpenNextTarget`
            // reads under also closes the unsynchronized write this
            // otherwise had on `gate`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                gate = continuation
                lock.unlock()
                onGatedOpenNextTargetEntry?()
            }
        }
        lock.lock()
        openNextTargetCallCount += 1
        lock.unlock()
        if let error { throw error }
    }
}

private final class FakeClawSiteNativeAPI: RelayStreamGuestNativeAPI, @unchecked Sendable {
    struct ConnectPersistentCall {
        let offerCbor: Data
        let expectedOwnerPub: Data
        let expectedGuestPub: Data
    }

    private let lock = NSLock()
    private var sessions: [FakeClawSiteNativeSession]
    private(set) var connectPersistentCallCount = 0
    private(set) var lastSession: FakeClawSiteNativeSession?
    private(set) var connectPersistentCalls: [ConnectPersistentCall] = []

    init(session: FakeClawSiteNativeSession) {
        self.sessions = [session]
    }

    init(sessions: [FakeClawSiteNativeSession]) {
        self.sessions = sessions
    }

    func prepareAuthSigningRequest(
        input: RelayStreamPrepareAuthInput
    ) throws -> RelayStreamAuthSigningRequest {
        RelayStreamAuthSigningRequest(
            authMode: .deviceCredential,
            signingBytes: Data([0x01, 0x02]),
            sessionId: input.sessionId,
            endpoint: "relay-stream://198.51.100.10:49152",
            targetId: "claw-alpha",
            expiresAt: input.nowUnix + input.ttlSecs,
            nonce: Data(repeating: 0x09, count: 16),
            authMaterialCbor: Data([0xA1, 0x01]),
            guestDevicePub: input.expectedGuestPub
        )
    }

    func connect(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        XCTFail("ClawSiteRelayStreamOpener must dial via connectPersistent, not legacy connect")
        return FakeClawSiteNativeSession()
    }

    func connectPersistent(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        nowUnix: UInt64,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        lock.lock()
        connectPersistentCallCount += 1
        let index = connectPersistentCallCount - 1
        let session = index < sessions.count ? sessions[index] : sessions[sessions.count - 1]
        lastSession = session
        connectPersistentCalls.append(ConnectPersistentCall(
            offerCbor: offerCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub
        ))
        lock.unlock()
        return session
    }
}
