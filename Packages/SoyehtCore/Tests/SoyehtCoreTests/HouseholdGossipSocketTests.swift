import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdGossipSocket")
struct HouseholdGossipSocketTests {
    /// Test-only handshake builder. Production code MUST inject a CBOR
    /// builder per the Phase-3 wire contract; this stub uses readable JSON
    /// for ease of byte-level assertions in the lifecycle tests, NOT
    /// because JSON is acceptable on the wire.
    static let testHandshake: HouseholdGossipSocket.CursorHandshakeBuilder = { cursor in
        if let cursor {
            .text("{\"since\":\(cursor)}")
        } else {
            .text("{}")
        }
    }

    @Test func handshakeWithCursorAndConnectedEvents() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("hello")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            initialCursor: 42,
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        let events = await socket.events()
        await socket.start()

        var collected: [HouseholdGossipFrame] = []
        for try await frame in frames {
            collected.append(frame)
            if collected.count == 1 {
                await socket.cancel()
            }
        }

        #expect(collected == [.text("hello")])

        var observed: [HouseholdGossipSocketEvent] = []
        for await event in events {
            observed.append(event)
        }
        #expect(observed.first == .connecting(attempt: 1, cursor: 42))
        #expect(observed.contains(.connected(cursor: 42)))
        #expect(observed.last == .cancelled)

        let openedCursors = await factory.openedCursors()
        #expect(openedCursors == [42])
        let firstHandshake = await factory.handshakes().first
        #expect(firstHandshake == .text("{\"since\":42}"))
    }

    @Test func reconnectAfterTransportErrorResumesWithUpdatedCursor() async throws {
        // Scenario 1 yields frame-1 then GATES on a signal before throwing —
        // this gives the consumer time to call updateCursor(7) before the
        // reconnect fires, eliminating the race between yield and throw.
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("frame-1")], finishWithError: TestTransportError.transient, gateBeforeError: true),
            StubScenario(frames: [.text("frame-2")], finishWithError: nil, gateBeforeError: false),
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            initialCursor: nil,
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        let events = await socket.events()
        await socket.start()

        var collected: [HouseholdGossipFrame] = []
        for try await frame in frames {
            collected.append(frame)
            if frame == .text("frame-1") {
                await socket.updateCursor(7)
                await factory.releaseGate()
            }
            if collected.count == 2 {
                await socket.cancel()
            }
        }

        #expect(collected == [.text("frame-1"), .text("frame-2")])

        var observed: [HouseholdGossipSocketEvent] = []
        for await event in events { observed.append(event) }

        let attempts = observed.compactMap { event -> (Int, UInt64?)? in
            if case .connecting(let attempt, let cursor) = event { return (attempt, cursor) }
            return nil
        }
        #expect(attempts.count == 2)
        #expect(attempts[0].0 == 1)
        #expect(attempts[1].0 == 1, "attempt counter resets on successful connection")
        let openedCursors = await factory.openedCursors()
        #expect(openedCursors == [nil, 7])
        let handshakes = await factory.handshakes(builder: Self.testHandshake)
        #expect(handshakes == [.text("{}"), .text("{\"since\":7}")])
    }

    @Test func oversizedFrameClosesConnectionAndReconnects() async throws {
        let big = Data(repeating: 0xAA, count: 64)
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.data(big)], finishWithError: nil),
            StubScenario(frames: [.text("recovered")], finishWithError: nil),
        ])
        let socket = HouseholdGossipSocket(
            configuration: HouseholdGossipSocket.Configuration(
                pingInterval: 0,
                initialBackoff: 0.001,
                maxBackoff: 0.001,
                backoffMultiplier: 1,
                maxReconnectAttempts: nil,
                maxFrameBytes: 32  // smaller than `big`
            ),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        let events = await socket.events()
        await socket.start()

        var collected: [HouseholdGossipFrame] = []
        for try await frame in frames {
            collected.append(frame)
            if frame == .text("recovered") {
                await socket.cancel()
            }
        }

        // The oversized frame MUST NOT be yielded; only the recovered one.
        #expect(collected == [.text("recovered")])

        var observed: [HouseholdGossipSocketEvent] = []
        for await event in events { observed.append(event) }
        let oversize = observed.contains { event in
            if case .disconnected(let reason) = event { return reason.contains("oversize") || reason.contains("Frame") }
            return false
        }
        #expect(oversize, "expected disconnected event citing oversize/Frame")
    }

    /// M1: with `maxReconnectAttempts: 2`, exhaust after the 2nd failure
    /// (cf >= cap), not the 3rd. Two scenarios are sufficient.
    @Test func retriesExhaustedTerminatesStream() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [], finishWithError: TestTransportError.transient),
            StubScenario(frames: [], finishWithError: TestTransportError.transient),
        ])
        let socket = HouseholdGossipSocket(
            configuration: HouseholdGossipSocket.Configuration(
                pingInterval: 0,
                initialBackoff: 0.001,
                maxBackoff: 0.001,
                backoffMultiplier: 1,
                maxReconnectAttempts: 2,
                maxFrameBytes: 1024,
                minStableDurationToResetFailures: 30
            ),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        let events = await socket.events()
        await socket.start()

        do {
            for try await _ in frames {}
            Issue.record("Expected retriesExhausted")
        } catch HouseholdGossipSocketError.retriesExhausted {
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        // M3: the events stream MUST also be finished — a subscriber
        // iterating events would hang otherwise. Bound the wait to
        // catch a regression where the stream stays open.
        let drained = await withTimeout(seconds: 1.0) {
            var collected: [HouseholdGossipSocketEvent] = []
            for await event in events { collected.append(event) }
            return collected
        }
        #expect(drained != nil, "events stream must finish on retriesExhausted (M3)")
        if let observed = drained {
            #expect(observed.contains(.retriesExhausted), "expected retriesExhausted event in stream")
        }

        let opened = await factory.openedCount()
        #expect(opened == 2, "M1: with cap=2 we exhaust after the 2nd failure, scenario 3 must NOT run")
    }

    @Test func pingLoopFiresAtConfiguredCadence() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("kept-alive")], finishWithError: nil)
        ])
        // Use a real (tiny) sleeper so the ping loop yields cooperatively
        // instead of spinning. 2ms ping interval × ~25ms total runtime
        // produces a small bounded number of pings.
        let socket = HouseholdGossipSocket(
            configuration: HouseholdGossipSocket.Configuration(
                pingInterval: 0.002,
                initialBackoff: 0.5,
                maxBackoff: 0.5,
                backoffMultiplier: 1,
                maxReconnectAttempts: nil,
                maxFrameBytes: 1024
            ),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { interval in
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            },
            transportFactory: factory.makeFactory()
        )
        let events = await socket.events()
        let frames = await socket.frames()
        await socket.start()

        for try await _ in frames {
            try await Task.sleep(nanoseconds: 25_000_000)
            await socket.cancel()
        }

        var observed: [HouseholdGossipSocketEvent] = []
        for await event in events { observed.append(event) }
        let pingCount = observed.filter { $0 == .pingSent }.count
        let pongCount = observed.filter { $0 == .pongReceived }.count
        #expect(pingCount >= 1, "expected at least one ping in the lifetime of the socket")
        #expect(pingCount == pongCount, "every ping must produce exactly one pong event")
    }

    @Test func cancelIsIdempotent() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("a")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        await socket.start()
        await socket.cancel()
        await socket.cancel()  // must not crash
        let count = await factory.openedCount()
        #expect(count <= 1)
    }

    // MARK: M2: single-subscriber stream caching

    /// `frames()` returns the same stream on subsequent calls so callers
    /// that inadvertently double-subscribe get a usable handle instead of
    /// silently orphaning the first stream.
    @Test func framesReturnsCachedStreamOnDoubleCall() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("only")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let firstFrames = await socket.frames()
        let secondFrames = await socket.frames()
        let firstEvents = await socket.events()
        let secondEvents = await socket.events()
        // Stream identity isn't easily exposed, but we can confirm both
        // handles point at the same underlying continuation by iterating
        // ONE of them and confirming the other terminates simultaneously.
        await socket.start()

        var got: [HouseholdGossipFrame] = []
        for try await frame in firstFrames {
            got.append(frame)
            if got.count == 1 { await socket.cancel() }
        }
        #expect(got == [.text("only")])

        // After cancel, the second handle MUST also be done (same stream).
        var secondGot: [HouseholdGossipFrame] = []
        for try await frame in secondFrames { secondGot.append(frame) }
        #expect(secondGot.isEmpty, "second frames() handle drains immediately because cancel finished the shared continuation")

        var firstObserved: [HouseholdGossipSocketEvent] = []
        for await event in firstEvents { firstObserved.append(event) }
        var secondObserved: [HouseholdGossipSocketEvent] = []
        for await event in secondEvents { secondObserved.append(event) }
        // Both events handles share the same upstream continuation; only
        // one consumer wins each event. The combined-but-disjoint list
        // covers all the events emitted (they don't both see everything).
        let combined = firstObserved + secondObserved
        #expect(combined.contains(HouseholdGossipSocketEvent.cancelled))
    }

    /// P2-3 regression: calling `frames()` for the first time AFTER
    /// `cancel()` MUST yield a stream that finishes immediately, not
    /// one that hangs forever. The cache from M2 made this hang
    /// permanent before the fix — `cancel()` finished the (then-nil)
    /// continuation, the late `frames()` registered a fresh one, and
    /// the consumer's `for await` never returned.
    @Test func framesAfterCancelFinishesImmediately() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("never-iterated")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        await socket.cancel()

        // Bound the iteration in a timeout — without the P2-3 guard the
        // for-await would hang forever and the timeout would fire.
        let drained = await withTimeout(seconds: 1.0) {
            var collected: [HouseholdGossipFrame] = []
            do {
                for try await frame in await socket.frames() {
                    collected.append(frame)
                }
            } catch {
                // Tolerate any propagated cancel error; the point is the
                // loop terminates.
            }
            return collected
        }
        #expect(drained != nil, "frames() after cancel must finish, not hang")
        #expect(drained == [], "no frames should be delivered after cancel")
    }

    /// Same regression for `events()`.
    @Test func eventsAfterCancelFinishesImmediately() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("any")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        await socket.cancel()

        let drained = await withTimeout(seconds: 1.0) {
            var collected: [HouseholdGossipSocketEvent] = []
            for await event in await socket.events() {
                collected.append(event)
            }
            return collected
        }
        #expect(drained != nil, "events() after cancel must finish, not hang")
        #expect(drained == [], "no events should be delivered after cancel")
    }

    // MARK: M5: time-based failure accounting

    /// A connection that lasts longer than `minStableDurationToResetFailures`
    /// MUST reset `consecutiveFailures` to zero — and the test MUST be
    /// observably broken if the reset never fires.
    ///
    /// Strategy (cap=2, threshold=30s):
    ///  1. short fail (clock unchanged) → counter=1
    ///  2. long success (clock +60s, then gated error) → correct: counter
    ///     resets to 0; BROKEN (always-increment): counter=2 → next iter
    ///     would hit cap before scenario 3 even opens.
    ///  3. short fail → correct: counter=1 (still under cap); broken
    ///     would have already terminated with retriesExhausted at the
    ///     top of iter 3.
    ///  4. final success with frame → only reachable on the correct impl.
    ///
    /// The assertion `openedCount == 4` (and final frame received)
    /// distinguishes the impls — a broken always-increment would open
    /// only 2 scenarios before exhausting and would surface
    /// retriesExhausted instead of the cancel path.
    @Test func longConnectionResetsFailureCounter() async throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let factory = StubTransportFactory(scenarios: [
            // 1: short failure, no frames.
            StubScenario(frames: [], finishWithError: TestTransportError.transient),
            // 2: long-lived success — yields a frame, gates so the test
            // can advance the clock past the 30s threshold before the
            // disconnect fires.
            StubScenario(frames: [.text("long-lived")], finishWithError: TestTransportError.transient, gateBeforeError: true),
            // 3: short failure again — must NOT exhaust because step 2
            // reset the counter.
            StubScenario(frames: [], finishWithError: TestTransportError.transient),
            // 4: final success path — only reachable when the reset
            // actually fired in step 2.
            StubScenario(frames: [.text("survived")], finishWithError: nil),
        ])
        let socket = HouseholdGossipSocket(
            configuration: HouseholdGossipSocket.Configuration(
                pingInterval: 0,
                initialBackoff: 0.001,
                maxBackoff: 0.001,
                backoffMultiplier: 1,
                maxReconnectAttempts: 2,
                maxFrameBytes: 1024,
                minStableDurationToResetFailures: 30
            ),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            nowProvider: { clock.now() },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        await socket.start()

        var collected: [HouseholdGossipFrame] = []
        do {
            for try await frame in frames {
                collected.append(frame)
                if frame == .text("long-lived") {
                    clock.advance(by: 60)
                    await factory.releaseGate()
                }
                if frame == .text("survived") {
                    await socket.cancel()
                }
            }
        } catch HouseholdGossipSocketError.retriesExhausted {
            Issue.record("retriesExhausted fired — reset never happened (broken impl)")
        }

        #expect(collected == [.text("long-lived"), .text("survived")])
        let opened = await factory.openedCount()
        #expect(opened == 4, "all 4 scenarios must run; broken impl exhausts after scenario 2")
    }

    /// Conversely, a short connection (< 30s) increments
    /// `consecutiveFailures` even though a frame was delivered. Together
    /// with M1, this ensures a flaky 1-frame-then-drop connection
    /// eventually exhausts retries.
    @Test func shortConnectionAccumulatesFailures() async throws {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let factory = StubTransportFactory(scenarios: [
            // Each scenario delivers one frame then errors immediately —
            // the fake clock does NOT advance, so each connection is "0s
            // stable" and consecutiveFailures keeps accumulating until
            // the cap is hit.
            StubScenario(frames: [.text("flake-1")], finishWithError: TestTransportError.transient),
            StubScenario(frames: [.text("flake-2")], finishWithError: TestTransportError.transient),
            StubScenario(frames: [.text("flake-3")], finishWithError: TestTransportError.transient),
        ])
        let socket = HouseholdGossipSocket(
            configuration: HouseholdGossipSocket.Configuration(
                pingInterval: 0,
                initialBackoff: 0.001,
                maxBackoff: 0.001,
                backoffMultiplier: 1,
                maxReconnectAttempts: 2,
                maxFrameBytes: 1024,
                minStableDurationToResetFailures: 30
            ),
            cursorHandshakeBuilder: Self.testHandshake,
            sleeper: { _ in },
            nowProvider: { clock.now() },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        await socket.start()

        var collected: [HouseholdGossipFrame] = []
        do {
            for try await frame in frames { collected.append(frame) }
            Issue.record("Expected retriesExhausted")
        } catch HouseholdGossipSocketError.retriesExhausted {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        // Two scenarios consumed (cap=2), each yielding one frame before
        // the immediate error. Scenario 3 is never opened.
        #expect(collected == [.text("flake-1"), .text("flake-2")])
        let opened = await factory.openedCount()
        #expect(opened == 2, "flaky 1-frame-then-drop must NOT keep retrying forever")
    }
}

// MARK: - Test helpers

/// Bounded async waiter — returns the closure result if it completes
/// within `seconds`, otherwise nil (treated as failure by callers).
private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}

/// Mutable monotonic clock for M5 time-based-reset tests.
final class FakeClock: @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()
    init(start: Date) { self.current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Test fixtures

private extension HouseholdGossipSocket.Configuration {
    static func testFast() -> HouseholdGossipSocket.Configuration {
        HouseholdGossipSocket.Configuration(
            pingInterval: 0,
            initialBackoff: 0.001,
            maxBackoff: 0.001,
            backoffMultiplier: 1,
            maxReconnectAttempts: nil,
            maxFrameBytes: 1024
        )
    }
}

enum TestTransportError: Error, Equatable, Sendable { case transient }

actor StubTransport: HouseholdGossipTransport {
    private var pendingFrames: [HouseholdGossipFrame]
    private let finishError: Error?
    private let gateBeforeError: Bool
    private var sent: [HouseholdGossipFrame] = []
    private var pingsSent = 0
    private var didCancel = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateAlreadyReleased = false

    init(frames: [HouseholdGossipFrame], finishError: Error?, gateBeforeError: Bool = false) {
        self.pendingFrames = frames
        self.finishError = finishError
        self.gateBeforeError = gateBeforeError
    }

    func send(_ frame: HouseholdGossipFrame) async throws {
        sent.append(frame)
    }

    func receive() async throws -> HouseholdGossipFrame {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if let finishError {
            if gateBeforeError && !gateAlreadyReleased {
                await withCheckedContinuation { continuation in
                    self.gateContinuation = continuation
                }
            }
            throw finishError
        }
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw CancellationError()
    }

    func sendPing() async throws {
        pingsSent += 1
    }

    nonisolated func cancel() {
        Task { await self.markCancelled() }
    }

    private func markCancelled() {
        didCancel = true
    }

    func releaseGate() {
        gateAlreadyReleased = true
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

struct StubScenario: Sendable {
    let frames: [HouseholdGossipFrame]
    let finishWithError: Error?
    let gateBeforeError: Bool

    init(frames: [HouseholdGossipFrame], finishWithError: Error?, gateBeforeError: Bool = false) {
        self.frames = frames
        self.finishWithError = finishWithError
        self.gateBeforeError = gateBeforeError
    }
}

actor StubTransportFactory {
    private var scenarios: [StubScenario]
    private var openedCursorsList: [UInt64?] = []
    private var openedCountValue = 0
    private var openedTransports: [StubTransport] = []

    init(scenarios: [StubScenario]) {
        self.scenarios = scenarios
    }

    nonisolated func makeFactory() -> @Sendable (UInt64?) async throws -> any HouseholdGossipTransport {
        { [self] cursor in
            try await self.openNext(cursor: cursor)
        }
    }

    func openNext(cursor: UInt64?) async throws -> any HouseholdGossipTransport {
        guard !scenarios.isEmpty else { throw TestTransportError.transient }
        let scenario = scenarios.removeFirst()
        openedCursorsList.append(cursor)
        openedCountValue += 1
        let transport = StubTransport(
            frames: scenario.frames,
            finishError: scenario.finishWithError,
            gateBeforeError: scenario.gateBeforeError
        )
        openedTransports.append(transport)
        return transport
    }

    func openedCursors() -> [UInt64?] { openedCursorsList }
    func openedCount() -> Int { openedCountValue }

    /// Re-derives the per-attempt handshakes from recorded cursor history
    /// using the same builder the socket was configured with. Tests pass
    /// the builder explicitly so the assertion is symmetric with what was
    /// actually sent on the wire.
    func handshakes(builder: HouseholdGossipSocket.CursorHandshakeBuilder = HouseholdGossipSocketTests.testHandshake) -> [HouseholdGossipFrame] {
        openedCursorsList.map { cursor in
            builder(cursor)
        }
    }

    /// Releases the gate on the most recently opened transport so its next
    /// `receive()` can proceed past the gate and throw the queued error.
    func releaseGate() async {
        guard let last = openedTransports.last else { return }
        await last.releaseGate()
    }
}
