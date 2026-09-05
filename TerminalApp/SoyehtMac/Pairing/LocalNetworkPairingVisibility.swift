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
    /// worth closing on the way out?
    private let openFlag = OpenFlag()

    /// Requests run in one chain so a fast open/close pair cannot land out of
    /// order and leave the home visible after the sheet is gone. Tests await it
    /// through `settle()`.
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
        openFlag.set(true)
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
        openFlag.set(false)
        stopRenewals()
        enqueue { requester in
            await Self.requestClose(requester)
        }
    }

    /// The app is quitting. `applicationWillTerminate` is the last moment a
    /// request can be made at all — an unawaited `Task` would simply not run —
    /// so this blocks the caller for at most
    /// ``terminationCloseTimeout``. Does nothing when no window is open.
    nonisolated func closeOnTermination() {
        guard openFlag.value else { return }
        openFlag.set(false)

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

    /// Awaits every request issued so far. Test seam; the app never needs it.
    func settle() async {
        await requestChain?.value
        await renewalTask?.value
    }

    // MARK: - Renewal

    private func startRenewals() {
        renewalTask?.cancel()
        let interval = renewInterval
        let sleeper = self.sleeper
        let requester = self.requester
        renewalTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleeper(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await Self.requestOpen(requester, stage: "renew")
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

/// A `Bool` the main actor writes and the termination path reads, with nothing
/// else riding along: `applicationWillTerminate` runs synchronously and cannot
/// await the actor that owns the reference count.
private final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

private extension Duration {
    /// `DispatchSemaphore` predates `Duration`; this is the only conversion.
    var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1_000_000_000_000_000_000
    }
}
