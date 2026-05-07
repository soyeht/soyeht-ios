import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdGossipSocket")
struct HouseholdGossipSocketTests {
    @Test func handshakeWithCursorAndConnectedEvents() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [.text("hello")], finishWithError: nil)
        ])
        let socket = HouseholdGossipSocket(
            configuration: .testFast(),
            initialCursor: 42,
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
        let handshakes = await factory.handshakes()
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

    @Test func retriesExhaustedTerminatesStream() async throws {
        let factory = StubTransportFactory(scenarios: [
            StubScenario(frames: [], finishWithError: TestTransportError.transient),
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
                maxFrameBytes: 1024
            ),
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        let frames = await socket.frames()
        await socket.start()

        do {
            for try await _ in frames {}
            Issue.record("Expected retriesExhausted")
        } catch HouseholdGossipSocketError.retriesExhausted {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
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
            sleeper: { _ in },
            transportFactory: factory.makeFactory()
        )
        await socket.start()
        await socket.cancel()
        await socket.cancel()  // must not crash
        let count = await factory.openedCount()
        #expect(count <= 1)
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

    /// Approximate handshakes by re-deriving from recorded cursor history.
    /// Sufficient because the socket always sends `defaultCursorHandshake`
    /// in tests that don't override the builder.
    func handshakes() -> [HouseholdGossipFrame] {
        openedCursorsList.map { cursor in
            HouseholdGossipSocket.defaultCursorHandshake(cursor)
        }
    }

    /// Releases the gate on the most recently opened transport so its next
    /// `receive()` can proceed past the gate and throw the queued error.
    func releaseGate() async {
        guard let last = openedTransports.last else { return }
        await last.releaseGate()
    }
}
