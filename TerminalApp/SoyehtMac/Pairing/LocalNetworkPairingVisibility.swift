import Foundation
import SoyehtCore
import os

private let localNetworkVisibilityLogger = Logger(
    subsystem: "com.soyeht.mac",
    category: "lan-pairing-visibility"
)

/// The network side of the pair-device window: what this Mac asks its own
/// engine to do while "Add iPhone" is on screen.
///
/// The owner's rule is that the home is discoverable on the local network in
/// exactly two situations — while the household has not been set up yet, and
/// while an "Add iPhone" window is open. The engine already implements the
/// second one, but on a household that is already set up nothing ever opened
/// the window it watches: the sheet shows an offer the Mac minted itself, and
/// the only route that opened an engine-side window is the first-owner
/// `GET /bootstrap/pair-device-uri`, which answers 404 once an owner exists
/// (measured against the Dev engine on 2026-09-04: 404 with `device_count=1`).
/// So the exposure policy saw `Closed` and the LAN never bound.
///
/// This object asks for visibility only. It does not mint, read or renew the
/// pairing offer — those six words belong to `MacPairingAdvertisement`, and one
/// offer per Mac is a rule this codebase has already been burned by.
///
/// Three properties this type exists to hold:
///
///   1. **Quiet failure.** A Mac whose engine does not answer still opens the
///      sheet, and a phone on the tailnet still pairs. Visibility is the bonus,
///      not the ceremony. Every failure here is logged and swallowed.
///   2. **Closes on every exit.** A window left open keeps the home visible on
///      the Wi-Fi, which is exactly what the owner asked to avoid — so the
///      sheet's completion, the window closing and the app quitting all land
///      here, and `closeOnTermination()` blocks briefly because a `Task` does
///      not survive `applicationWillTerminate`.
///   3. **Outlives the engine's own time box.** The engine window is
///      time-boxed (the pair-device TTL floor is 60 s) so a forgotten window
///      cannot keep the home visible forever. A sheet someone leaves open for
///      ten minutes would therefore go quiet halfway through, so this renews
///      well under that floor; a repeat open extends rather than mints.
@MainActor
final class LocalNetworkPairingVisibility {
    static let shared = LocalNetworkPairingVisibility()

    /// Renew comfortably under the engine's 60 s TTL floor, so the Mac never
    /// has to know the engine's configured TTL to keep an open sheet visible.
    nonisolated static let defaultRenewInterval: Duration = .seconds(20)

    /// Bounded because it runs on the main thread inside
    /// `applicationWillTerminate`. The engine is on loopback, so the real cost
    /// is sub-millisecond; the bound only caps a quit against an engine that
    /// has stopped answering.
    nonisolated static let terminationCloseTimeout: Duration = .milliseconds(750)

    private let requester: any LocalNetworkPairingVisibilityRequesting
    private let renewInterval: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    /// Reference-counted, like `MacPairingAdvertisement`: more than one surface
    /// can want the home visible at once, and only the last one to leave closes
    /// the window.
    private var interestedParties = 0

    /// Read from the non-isolated termination path, which cannot touch
    /// `interestedParties`. It answers exactly one question: is there a window
    /// at the engine that nobody has closed yet?
    private let latch = VisibilityLatch()

    /// Which open/close cycle we are in. Carried by each close so a close
    /// enqueued for a sheet that is already gone cannot clear a window a NEWER
    /// sheet has since opened.
    private var cycle: UInt64 = 0

    /// Requests run in one chain so a fast open/close pair cannot land out of
    /// order and leave the home visible after the sheet is gone. Renewals go
    /// through it too: a renewal issued outside the chain can be answered by
    /// the engine AFTER the close that followed it, which re-opens the window
    /// the person just dismissed and leaves the home on the Wi-Fi until the
    /// engine's TTL runs out. Tests await it through `settle()`.
    private var requestChain: Task<Void, Never>?
    /// Exposed to the module so the renewal loop can be awaited in a test
    /// instead of slept on.
    private(set) var renewalTask: Task<Void, Never>?

    init(
        requester: any LocalNetworkPairingVisibilityRequesting = LiveLocalNetworkPairingVisibilityRequester(),
        renewInterval: Duration = LocalNetworkPairingVisibility.defaultRenewInterval,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.requester = requester
        self.renewInterval = renewInterval
        self.sleeper = sleeper
    }

    /// The "Add iPhone" surface is on screen: ask the engine to be visible on
    /// the local network.
    func begin() {
        interestedParties += 1
        guard interestedParties == 1 else { return }
        cycle += 1
        latch.opened(cycle: cycle)
        enqueue { requester in
            await Self.requestOpen(requester, stage: "open")
        }
        startRenewals()
    }

    /// The "Add iPhone" surface is gone by any route: stop being visible.
    func end() {
        guard interestedParties > 0 else { return }
        interestedParties -= 1
        guard interestedParties == 0 else { return }
        stopRenewals()
        let closing = cycle
        let latch = self.latch
        enqueue { requester in
            // Claimed rather than assumed: the same window can be closed by
            // this chain or by `closeOnTermination()`, whichever gets there
            // first, and a re-opened sheet must not be closed by the close its
            // predecessor left in the queue.
            guard latch.claimClose(cycle: closing) else { return }
            await Self.requestClose(requester)
        }
    }

    /// The app is quitting. `applicationWillTerminate` is the last moment a
    /// request can be made at all — an unawaited `Task` would simply not run —
    /// so this blocks the caller for at most ``terminationCloseTimeout``.
    ///
    /// The gate is "is there a window nobody has closed yet", NOT "is a sheet
    /// on screen": dismissing the sheet and quitting in the same breath used to
    /// leave the close sitting in a queue that the dying process never drained,
    /// and the home stayed on the Wi-Fi until the engine's TTL expired.
    nonisolated func closeOnTermination() {
        guard latch.claimCloseOnTermination() else { return }

        let requester = self.requester
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await Self.requestClose(requester)
            done.signal()
        }
        if done.wait(timeout: .now() + Self.terminationCloseTimeout.timeIntervalValue) == .timedOut {
            localNetworkVisibilityLogger.error(
                "LAN pairing visibility: close on quit timed out; the engine's own window TTL is the remaining backstop"
            )
        }
    }

    /// Awaits every request issued so far. Renewals first: they enqueue onto
    /// the chain, so awaiting the chain before them would miss the very
    /// requests the renewal loop is about to add. Test seam; the app never
    /// needs it.
    func settle() async {
        await renewalTask?.value
        await requestChain?.value
    }

    // MARK: - Renewal

    private func startRenewals() {
        renewalTask?.cancel()
        let interval = renewInterval
        let sleeper = self.sleeper
        renewalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                // Onto the chain, never straight to the engine: `end()` runs on
                // this same actor and cancels above, so a renewal that gets
                // here is genuinely earlier than the close and must be ordered
                // before it.
                self.enqueue { requester in
                    await Self.requestOpen(requester, stage: "renew")
                }
            }
        }
    }

    private func stopRenewals() {
        renewalTask?.cancel()
        renewalTask = nil
    }

    // MARK: - Request plumbing

    private func enqueue(_ work: @escaping @Sendable (any LocalNetworkPairingVisibilityRequesting) async -> Void) {
        let previous = requestChain
        let requester = self.requester
        requestChain = Task { @MainActor in
            await previous?.value
            await work(requester)
        }
    }

    nonisolated private static func requestOpen(
        _ requester: any LocalNetworkPairingVisibilityRequesting,
        stage: String
    ) async {
        do {
            let ack = try await requester.open()
            localNetworkVisibilityLogger.info(
                "LAN pairing visibility \(stage, privacy: .public): engine window open, expires_at=\(ack.expiresAt.map(String.init) ?? "unset", privacy: .public)"
            )
        } catch {
            // Quiet on purpose: the sheet still opens and a phone on the
            // tailnet still pairs. Visibility is the bonus, not the ceremony.
            localNetworkVisibilityLogger.error(
                "LAN pairing visibility \(stage, privacy: .public) failed; continuing without local-network discovery: \(String(describing: error), privacy: .public)"
            )
        }
    }

    nonisolated private static func requestClose(_ requester: any LocalNetworkPairingVisibilityRequesting) async {
        do {
            try await requester.close()
            localNetworkVisibilityLogger.info("LAN pairing visibility: engine window closed")
        } catch {
            localNetworkVisibilityLogger.error(
                "LAN pairing visibility close failed; the engine's own window TTL is the remaining backstop: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

/// The two asks, behind a protocol so the coordinator's exit paths can be
/// tested without an engine.
protocol LocalNetworkPairingVisibilityRequesting: Sendable {
    @discardableResult
    func open() async throws -> BootstrapPairDeviceWindowAck
    func close() async throws
}

/// Talks to this Mac's own engine. `TheyOSEnvironment.bootstrapBaseURL` is
/// resolved per call rather than captured, so Dev and production each reach
/// their own engine on their own bootstrap port.
struct LiveLocalNetworkPairingVisibilityRequester: LocalNetworkPairingVisibilityRequesting {
    private let baseURL: @Sendable () -> URL

    init(baseURL: @escaping @Sendable () -> URL = { TheyOSEnvironment.bootstrapBaseURL }) {
        self.baseURL = baseURL
    }

    @discardableResult
    func open() async throws -> BootstrapPairDeviceWindowAck {
        try await BootstrapPairDeviceWindowClient(baseURL: baseURL()).open()
    }

    func close() async throws {
        _ = try await BootstrapPairDeviceWindowClient(baseURL: baseURL()).close()
    }
}

/// The one fact the main actor and the termination path share: is there a
/// window at the engine that nobody has closed yet, and which cycle opened it?
/// `applicationWillTerminate` runs synchronously and cannot await the actor
/// that owns the reference count, so this is a lock and not an actor.
///
/// It holds a cycle rather than a `Bool` because both a claim and a re-open can
/// race the queue:
///
///   - dismiss and quit in the same breath: the close is still queued, and the
///     process dies before the queue drains. The quit path has to see work
///     outstanding, which a "is a sheet on screen" flag does not report.
///   - dismiss and re-open: the first close is still queued when the second
///     sheet opens. Closing then would take down a window the person is
///     looking at, so a close only fires for the cycle it was made for.
private final class VisibilityLatch: @unchecked Sendable {
    private let lock = NSLock()
    /// The cycle whose window is believed open at the engine; nil when there
    /// is nothing left to close.
    private var openCycle: UInt64?

    func opened(cycle: UInt64) {
        lock.lock()
        openCycle = cycle
        lock.unlock()
    }

    /// True exactly once per cycle, for whoever gets here first.
    func claimClose(cycle: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openCycle == cycle else { return false }
        openCycle = nil
        return true
    }

    /// Quitting closes whatever is open, whichever cycle left it that way.
    func claimCloseOnTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openCycle != nil else { return false }
        openCycle = nil
        return true
    }
}

private extension Duration {
    /// `DispatchSemaphore` predates `Duration`; this is the only conversion.
    var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
    }
}
