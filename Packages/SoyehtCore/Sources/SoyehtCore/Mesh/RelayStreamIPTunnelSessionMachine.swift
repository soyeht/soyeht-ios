import Foundation

/// A data-plane session the tunnel lifecycle can close.
///
/// Deliberately minimal: the lifecycle owner never reads from a session, it only
/// guarantees the session is closed exactly once when it is discarded.
public protocol RelayStreamIPTunnelClosableSession: Sendable {
    func closeSession() async
}

/// Serial owner of the `IpTunnel` provider lifecycle.
///
/// WHY SYNCHRONOUS AND LOCK-PROTECTED, NOT AN ACTOR.
/// `NEPacketTunnelProvider` delivers `startTunnel`/`stopTunnel` as SYNCHRONOUS
/// callbacks, and their relative order is the only ordering the system gives us.
/// An actor would force every transition behind `await` from an unstructured
/// `Task`, and the order in which those tasks are enqueued is NOT the order the
/// callbacks fired. That loses the one guarantee worth having: `stopTunnel`
/// could spawn its task, find an idle machine, complete as a no-op, and only
/// afterwards would the start task run `begin()` — resurrecting a tunnel the
/// system already tore down.
///
/// Making every transition a synchronous call under one lock means the overrides
/// commit their intent AT the callback, in callback order, before any task
/// exists. Ordering is then inherited from NetworkExtension instead of from the
/// cooperative pool's scheduling.
///
/// The invariants, and the mechanism that produces each:
///
///   * **Epoch.** `begin()` issues a monotonically increasing epoch; `stop()`
///     bumps it. Every later transition names the epoch it belongs to, so any
///     stop permanently invalidates work already in flight, whenever it lands.
///   * **Activation installs BEFORE it pumps, both under the lock.** `activate`
///     sets `.running` and stores the session first, then creates and registers
///     the pump while still holding the lock. A pump that finishes instantly
///     therefore blocks in `pumpFinished` until activation releases the lock,
///     and then observes a coherent `.running` state to clean up — instead of
///     racing a half-installed one.
///   * **Typed cleanup per outcome.** `startFailed(epoch:)` clears only a
///     still-current `.starting`; `pumpFinished(epoch:)` clears and hands back
///     only a still-current `.running`. A stale caller is ignored, so late
///     cleanup from a superseded generation can never disturb a newer one.
///
/// Consequences: a session from a start that lost the race is refused and
/// returned for closing before any pump exists; a pump is never created after a
/// stop; repeated stops are no-ops; and the machine returns to `.idle` on every
/// terminal path, so a restart is always accepted.
///
/// COST OF NOT CANCELLING AN IN-FLIGHT CONNECT. `stop()` cancels the start task,
/// but a connect already blocked in a network read may not unwind until its own
/// timeout. That is accepted: the epoch has already invalidated it, so the
/// session it eventually produces is refused and closed without ever being
/// pumped. The visible cost is that the task, its socket and its buffers stay
/// resident until that timeout expires, while the tunnel is already gone from
/// the system's point of view.
public final class RelayStreamIPTunnelSessionMachine: @unchecked Sendable {
    public typealias Epoch = UInt64

    /// Result of trying to install a connected session.
    public enum ActivationOutcome: Sendable, Equatable {
        /// Installed under a still-current epoch; the pump was created.
        case activated
        /// A stop (or a newer generation) invalidated this attempt. The caller
        /// owns the session and MUST close it; no pump was created.
        case superseded
    }

    private enum State {
        case idle
        case starting(Epoch)
        case running(Epoch)
        /// The pump lost the session and is emitting the system-level cancel.
        ///
        /// Deliberately NOT `.idle`: reporting a failure is two steps — decide
        /// who owns the teardown, then tell the system — and between them the
        /// machine must refuse a new start. Going idle at step one lets a fresh
        /// `begin()` be accepted, and the cancel emitted at step two would then
        /// tear down that newer generation instead of the failed one.
        case failing(Epoch)
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var epochCounter: Epoch = 0
    private var session: (any RelayStreamIPTunnelClosableSession)?
    private var pumpTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    public init() {}

    /// Claim the lifecycle. Call SYNCHRONOUSLY from `startTunnel`, before
    /// spawning anything, so the claim is ordered against `stop()` by the
    /// callback order rather than by task scheduling.
    ///
    /// `nil` when a start is already in flight or a tunnel is running.
    public func begin() -> Epoch? {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = state else { return nil }
        epochCounter &+= 1
        state = .starting(epochCounter)
        return epochCounter
    }

    /// Hand the driving task over so `stop()` can cancel it. A stale epoch means
    /// a stop already landed, so the task is cancelled instead of adopted and
    /// cannot resurrect the lifecycle.
    public func adoptStartTask(_ task: Task<Void, Never>, epoch: Epoch) {
        lock.lock()
        guard case .starting(let active) = state, active == epoch else {
            lock.unlock()
            task.cancel()
            return
        }
        startTask = task
        lock.unlock()
    }

    /// Install a connected session and start pumping it, atomically.
    ///
    /// Order inside the lock is load-bearing: session and `.running` are
    /// published FIRST, then `makePump()` runs while the lock is still held.
    /// A pump that completes immediately blocks in `pumpFinished` until this
    /// returns, and then sees a fully installed `.running` to tear down.
    public func activate(
        session newSession: any RelayStreamIPTunnelClosableSession,
        epoch: Epoch,
        makePump: () -> Task<Void, Never>
    ) -> ActivationOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(let active) = state, active == epoch else {
            return .superseded
        }
        session = newSession
        state = .running(epoch)
        startTask = nil
        pumpTask = makePump()
        return .activated
    }

    /// A start that threw before activating. Clears only a still-current
    /// `.starting`, so a late failure from a superseded generation is ignored.
    public func startFailed(epoch: Epoch) {
        lock.lock()
        defer { lock.unlock() }
        guard case .starting(let active) = state, active == epoch else { return }
        startTask = nil
        state = .idle
    }

    /// The pump ended cleanly.
    ///
    /// OWNERSHIP: the returned session is the caller's to close, and `nil` means
    /// somebody else — `stop()`, or a newer generation — already took it. A
    /// caller that closes on `nil` double-closes a session it does not own.
    public func pumpFinished(epoch: Epoch) -> (any RelayStreamIPTunnelClosableSession)? {
        lock.lock()
        defer { lock.unlock() }
        guard case .running(let active) = state, active == epoch else { return nil }
        pumpTask = nil
        let closing = session
        session = nil
        state = .idle
        return closing
    }

    /// The pump ended with an error and wants to raise it to the system.
    ///
    /// Same ownership rule as `pumpFinished`: `nil` means the teardown is not
    /// this caller's, so it must neither close nor cancel. On success the
    /// machine moves to `.failing` and stays there — NOT `.idle` — so no new
    /// start can be accepted while the caller is emitting the cancel. The
    /// caller MUST finish with `failureReported(epoch:)`.
    public func pumpFailed(epoch: Epoch) -> (any RelayStreamIPTunnelClosableSession)? {
        lock.lock()
        defer { lock.unlock() }
        guard case .running(let active) = state, active == epoch else { return nil }
        pumpTask = nil
        let closing = session
        session = nil
        state = .failing(epoch)
        return closing
    }

    /// The system-level cancel for a failed pump has been emitted; release the
    /// machine for a restart. Only a still-current `.failing` is released, so a
    /// duplicate or late report cannot disturb a later generation.
    public func failureReported(epoch: Epoch) {
        lock.lock()
        defer { lock.unlock() }
        guard case .failing(let active) = state, active == epoch else { return }
        state = .idle
    }

    /// Tear down. Call SYNCHRONOUSLY from `stopTunnel`, before spawning the task
    /// that closes the session, so the teardown is ordered against `begin()`.
    ///
    /// Returns the session the caller must close, or `nil` when there is nothing
    /// to close. Idempotent.
    ///
    /// A stop that lands in `.failing` deliberately does NOT release the
    /// machine. `pumpFailed` has already taken the session and pump task, but
    /// the old generation has not yet emitted its system-level cancel. Going
    /// idle here would admit a new start that the old cancel could tear down.
    /// `failureReported(epoch:)` releases this short, non-suspending window
    /// immediately after the cancel call returns.
    public func stop() -> (any RelayStreamIPTunnelClosableSession)? {
        lock.lock()
        epochCounter &+= 1
        let cancellingStart = startTask
        startTask = nil
        let cancellingPump = pumpTask
        pumpTask = nil
        let closing = session
        session = nil
        if case .failing = state {
            // Keep the failure fence until the system cancel is emitted.
        } else {
            state = .idle
        }
        lock.unlock()

        // Cancelled outside the lock: a cancellation handler that reaches back
        // into the machine would otherwise deadlock on a non-reentrant lock.
        cancellingStart?.cancel()
        cancellingPump?.cancel()
        return closing
    }

    // MARK: - Observation (read-only; behaviour never varies for tests)

    public var isPumping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pumpTask != nil
    }

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .idle = state { return true }
        return false
    }
}
