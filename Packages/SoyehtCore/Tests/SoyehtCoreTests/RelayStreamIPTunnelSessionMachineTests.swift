import Foundation
import Testing

@testable import SoyehtCore

/// Lifecycle races in the `IpTunnel` provider, driven by explicit barriers.
///
/// Every ordering is forced with continuations the test resumes itself. Nothing
/// sleeps and nothing polls, so a failure means an invariant broke, not that a
/// machine was slow.
@Suite("RelayStream IpTunnel session machine")
struct RelayStreamIPTunnelSessionMachineTests {
    /// Counts its own closes, so "the losing session is closed" is checked
    /// against the session rather than inferred from a return value.
    private final class SpySession: RelayStreamIPTunnelClosableSession, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        // `NSLock.lock()`/`unlock()` are unavailable from an async context and
        // become an error under Swift 6, so the critical section lives in a
        // synchronous helper the async requirement calls. Same semantics: one
        // lock/unlock pair per close, still no suspension while held.
        func closeSession() async {
            recordClose()
        }

        private func recordClose() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var closes: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// A barrier the test opens by hand.
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    c.resume()
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    private final class Counter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// WINDOW 1 — stop lands after the start intent but BEFORE the driver has
    /// begun connecting.
    ///
    /// This is the window an actor-based machine cannot close: the two overrides
    /// are synchronous, so if the claim were made inside a spawned task the stop
    /// could complete first on an idle machine and the start would then
    /// resurrect the tunnel. Because `begin()` is synchronous, the claim and the
    /// stop are ordered by the callback order, and the later activation is
    /// refused.
    @Test func stopRightAfterStartIntentPreventsAnyLaterActivation() async {
        let machine = RelayStreamIPTunnelSessionMachine()

        let epoch = machine.begin()
        #expect(epoch != nil, "a fresh machine must accept a start")

        #expect(machine.stop() == nil, "nothing installed yet, so nothing to close")

        // The driver only now gets as far as producing a session.
        let session = SpySession()
        let pumps = Counter()
        let outcome = machine.activate(session: session, epoch: epoch!) {
            pumps.increment()
            return Task {}
        }

        #expect(outcome == .superseded)
        #expect(pumps.value == 0, "the pump factory must not run for a stale epoch")
        #expect(machine.isPumping == false)
        #expect(machine.isIdle)
    }

    /// WINDOW 2 — stop lands while the connect is still suspended.
    ///
    /// The connect is held at a barrier, stop runs, the connect is released and
    /// produces a session. That session must be refused and closed, with no pump.
    @Test func stopDuringConnectRefusesAndClosesTheLateSession() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let connectEntered = Gate()
        let releaseConnect = Gate()

        let epoch = machine.begin()
        #expect(epoch != nil)

        let session = SpySession()
        let pumps = Counter()
        let driver = Task { () -> RelayStreamIPTunnelSessionMachine.ActivationOutcome in
            connectEntered.open()
            await releaseConnect.wait()
            return machine.activate(session: session, epoch: epoch!) {
                pumps.increment()
                return Task {}
            }
        }

        await connectEntered.wait() // the connect is in flight and has not returned
        #expect(machine.stop() == nil)

        releaseConnect.open()
        let outcome = await driver.value
        #expect(outcome == .superseded, "a start that lost to stop must not install")
        #expect(pumps.value == 0)

        await session.closeSession() // the caller owns the refused session
        #expect(session.closes == 1)
        #expect(machine.isPumping == false)
        #expect(machine.isIdle)
    }

    /// WINDOW 3 — the pump finishes INSTANTLY, while activation still holds the
    /// lock.
    ///
    /// Its cleanup must block until activation has published `.running`, then
    /// observe a coherent state and tear it down — never a half-installed one,
    /// and never leaving the machine stuck in `.running`.
    @Test func pumpFinishingImmediatelyDuringActivateLeavesNoRunningState() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()
        let session = SpySession()
        let cleanupDone = Gate()

        let outcome = machine.activate(session: session, epoch: epoch!) {
            Task {
                // Reaches back into the machine while `activate` still holds the
                // lock; this must block rather than observe a partial state.
                let closing = machine.pumpFinished(epoch: epoch!)
                await closing?.closeSession()
                cleanupDone.open()
            }
        }
        #expect(outcome == .activated)

        await cleanupDone.wait()
        #expect(session.closes == 1, "the pump's own cleanup closes the session once")
        #expect(machine.isPumping == false)
        #expect(machine.isIdle, "an instantly-finished pump must not strand .running")
        #expect(machine.begin() != nil, "and the machine must still be restartable")
    }

    /// A pump that ends later cleans up and frees the machine for a restart.
    @Test func pumpFinishedClosesTheSessionAndAllowsRestart() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()
        let session = SpySession()
        #expect(machine.activate(session: session, epoch: epoch!) { Task {} } == .activated)
        #expect(machine.isPumping)

        let closing = machine.pumpFinished(epoch: epoch!)
        #expect(closing != nil, "the running session comes back for closing")
        await closing?.closeSession()
        #expect(session.closes == 1)
        #expect(machine.isIdle)
        #expect(machine.begin() != nil)
    }

    /// The epoch, isolated from the state check.
    ///
    /// After stop the state is `.idle`, so a stale activation is refused on the
    /// state alone and the epoch proves nothing. The epoch only earns its keep
    /// once a NEW generation is already `.starting`: without the equality check
    /// the previous generation's session would install into it, handing the new
    /// tunnel a socket its caller believes was abandoned. A mutation removing
    /// the epoch comparison must fail HERE.
    @Test func aSupersededStartCannotInstallIntoTheNextGeneration() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let superseded = machine.begin()!
        _ = machine.stop()

        let current = machine.begin()
        #expect(current != nil)
        #expect(current != superseded)

        let staleSession = SpySession()
        let pumps = Counter()
        let outcome = machine.activate(session: staleSession, epoch: superseded) {
            pumps.increment()
            return Task {}
        }

        #expect(outcome == .superseded, "an old generation must not install into a new one")
        #expect(pumps.value == 0)
        #expect(machine.isPumping == false, "the new generation must still be un-pumped")
    }

    /// TEARDOWN OWNERSHIP 1 — stop wins, then the pump finishes cleanly.
    ///
    /// `stop()` already took the session and its own task closes it. The pump
    /// must be told it owns nothing and must NOT close again: the session is
    /// closed exactly once in total.
    @Test func stopWinsThenCleanPumpFinishClosesExactlyOnce() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()!
        let session = SpySession()
        #expect(machine.activate(session: session, epoch: epoch) { Task {} } == .activated)

        // stop wins the race and takes ownership.
        let stopClosing = machine.stop()
        #expect(stopClosing != nil, "stop owns the session")
        await stopClosing?.closeSession()

        // The pump only now returns from a clean run.
        #expect(
            machine.pumpFinished(epoch: epoch) == nil,
            "the pump must be told it owns nothing"
        )
        #expect(session.closes == 1, "exactly one close in total, not two")
    }

    /// TEARDOWN OWNERSHIP 2 — stop wins, then the pump fails.
    ///
    /// The failure is not this generation's to report: no session close, and no
    /// system cancel, because a cancel here would tear down whatever ran next.
    @Test func stopWinsThenPumpErrorNeitherClosesNorCancels() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()!
        let session = SpySession()
        #expect(machine.activate(session: session, epoch: epoch) { Task {} } == .activated)

        let stopClosing = machine.stop()
        await stopClosing?.closeSession()

        // The pump errors out after losing the race.
        let owned = machine.pumpFailed(epoch: epoch)
        #expect(owned == nil, "a superseded pump owns no teardown")
        #expect(session.closes == 1, "exactly one close, from stop")

        // A cancel gated on that nil never fires — modelled by the machine
        // staying idle and restartable rather than stuck in .failing.
        #expect(machine.isIdle)
        #expect(machine.begin() != nil, "the next generation is unaffected")
    }

    /// TEARDOWN OWNERSHIP 3 — the pump failure wins.
    ///
    /// It owns the session, and the machine must refuse a concurrent start
    /// until the system cancel has actually been emitted. Releasing at the
    /// moment of the decision instead would let a new tunnel start and then be
    /// cancelled by the previous generation's error.
    @Test func failingPumpBlocksRestartUntilTheCancelIsEmitted() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()!
        let session = SpySession()
        #expect(machine.activate(session: session, epoch: epoch) { Task {} } == .activated)

        let owned = machine.pumpFailed(epoch: epoch)
        #expect(owned != nil, "the failing pump owns the session")
        await owned?.closeSession()
        #expect(session.closes == 1)

        // The window in which the cancel is being emitted: no new start.
        #expect(
            machine.begin() == nil,
            "a start accepted here would be cancelled by the previous failure"
        )
        #expect(machine.isIdle == false)

        // Cancel emitted; only now is the machine released.
        machine.failureReported(epoch: epoch)
        #expect(machine.isIdle)
        #expect(machine.begin() != nil, "restart is allowed after safe teardown")
    }

    /// A stop during the failure window must NOT release the machine before the
    /// old generation emits its system cancel. Otherwise a fresh start can be
    /// admitted and then torn down by that old cancel.
    @Test func stopDuringFailureWindowKeepsTheCancelFence() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()!
        #expect(machine.activate(session: SpySession(), epoch: epoch) { Task {} } == .activated)
        _ = machine.pumpFailed(epoch: epoch)

        #expect(machine.stop() == nil, "the failing pump already took the session")
        #expect(machine.isIdle == false, "stop must preserve the failure fence")
        #expect(
            machine.begin() == nil,
            "no new generation may start before the old cancel is emitted"
        )

        // The cancel has now been emitted; only this report releases the fence.
        machine.failureReported(epoch: epoch)
        #expect(machine.isIdle)
        let newer = machine.begin()
        #expect(newer != nil, "restart is allowed after the cancel is emitted")

        // A duplicate report from the dead generation cannot disturb the new
        // start.
        machine.failureReported(epoch: epoch)
        #expect(machine.isIdle == false, "the newer generation is still starting")
    }

    /// Cleanup is epoch-scoped: a stale generation cannot disturb a newer one.
    @Test func staleCleanupIsIgnored() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let stale = machine.begin()!
        _ = machine.stop()

        machine.startFailed(epoch: stale) // must not touch the fresh generation
        let fresh = machine.begin()
        #expect(fresh != nil)
        #expect(fresh != stale)

        let session = SpySession()
        #expect(machine.activate(session: session, epoch: fresh!) { Task {} } == .activated)
        #expect(machine.pumpFinished(epoch: stale) == nil, "a stale pump must clean nothing")
        #expect(machine.isPumping, "the current generation is untouched")
    }

    /// A failed start releases the claim without a session, and only its own.
    @Test func startFailedReleasesTheClaimForRestart() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()
        #expect(machine.begin() == nil, "a second start is refused while one is in flight")

        machine.startFailed(epoch: epoch!)
        #expect(machine.isIdle)
        #expect(machine.begin() != nil, "a failed start must not wedge the machine")
    }

    /// Stop is idempotent and a restart is accepted afterwards.
    @Test func stopIsIdempotentAndRestartIsAccepted() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()
        let session = SpySession()
        #expect(machine.activate(session: session, epoch: epoch!) { Task {} } == .activated)

        let first = machine.stop()
        #expect(first != nil, "the running session must come back for closing")
        await first?.closeSession()
        #expect(machine.stop() == nil, "a repeated stop closes nothing and does not trap")
        #expect(machine.isIdle)
        #expect(machine.begin() != nil, "the machine must be restartable")
    }

    /// The pump is created exactly once on the accepted path.
    @Test func thePumpIsCreatedExactlyOnce() async {
        let machine = RelayStreamIPTunnelSessionMachine()
        let epoch = machine.begin()
        let pumps = Counter()
        #expect(
            machine.activate(session: SpySession(), epoch: epoch!) {
                pumps.increment()
                return Task {}
            } == .activated
        )
        #expect(pumps.value == 1)
        #expect(machine.isPumping)
    }
}
