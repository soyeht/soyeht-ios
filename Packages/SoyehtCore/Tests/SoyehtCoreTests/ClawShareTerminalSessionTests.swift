import Foundation
import XCTest

@testable import SoyehtCore

/// Contract tests for the claw-share terminal driver. These pin the
/// terminal path's behaviour — open gate by `.interactiveReady`, keyboard
/// stdin, resize propagation, output delivery, and recoverable teardown —
/// against a controllable fake data-plane client. No live engine / PTY is
/// needed (CI can't run one); the real PTY round-trip is proven by the
/// Rust engine tests, and the iPhone↔engine↔shell path by the documented
/// manual smoke.
final class ClawShareTerminalSessionTests: XCTestCase {
    // MARK: - Fakes

    /// Records output + end notifications for assertions.
    private actor RecordingOutput: ClawShareTerminalOutput {
        private(set) var chunks: [Data] = []
        private(set) var endedReason: String?
        private var feedWaiters: [CheckedContinuation<Data, Never>] = []

        func feed(_ bytes: Data) async {
            if feedWaiters.isEmpty { chunks.append(bytes) }
            else { feedWaiters.removeFirst().resume(returning: bytes) }
        }
        func sessionEnded(reason: String) async { endedReason = reason }

        /// Await the next fed chunk (or return a buffered one).
        func nextChunk() async -> Data {
            if !chunks.isEmpty { return chunks.removeFirst() }
            return await withCheckedContinuation { feedWaiters.append($0) }
        }
        func ended() -> String? { endedReason }
    }

    /// A fake client whose `openStream` result and `receiveData` stream are
    /// scriptable, and which records sent input + resizes.
    private actor ScriptClient: ClawShareDataPlaneClient {
        var openStatus: ClawShareSessionStatus = .interactiveReady(sinceUnix: 7)
        private var outbox: [Result<Data, Error>] = []
        private var recvWaiters: [CheckedContinuation<Data, Error>] = []
        private(set) var sent: [Data] = []
        private(set) var resizes: [(UInt16, UInt16)] = []
        private(set) var stopped = false

        init(openStatus: ClawShareSessionStatus = .interactiveReady(sinceUnix: 7)) {
            self.openStatus = openStatus
        }

        /// Queue an output chunk the read loop will deliver.
        func pushOutput(_ data: Data) {
            if recvWaiters.isEmpty { outbox.append(.success(data)) }
            else { recvWaiters.removeFirst().resume(returning: data) }
        }
        /// Queue an end-of-stream (clean close / exit).
        func pushEnd() {
            if recvWaiters.isEmpty { outbox.append(.failure(ClawShareDataPlaneError.noSession)) }
            else { recvWaiters.removeFirst().resume(throwing: ClawShareDataPlaneError.noSession) }
        }

        func loadCredential(_ c: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus { .credentialReady }
        func startSession(endpoint: ClawShareDataPlaneEndpoint, sessionToken: Data) async throws -> ClawShareStartOutcome {
            ClawShareStartOutcome(meshIPv6: "fd00:c1aw::1", mtu: 1280, sessionId: "t", status: .awaitingFirstPacket)
        }
        func healthPing() async throws -> ClawShareSessionStatus { .connected(sinceUnix: 1) }
        func openStream() async throws -> ClawShareSessionStatus { openStatus }
        func sendData(_ packet: Data) async throws { sent.append(packet) }
        func receiveData() async throws -> Data {
            if !outbox.isEmpty { return try outbox.removeFirst().get() }
            return try await withCheckedThrowingContinuation { recvWaiters.append($0) }
        }
        func resize(cols: UInt16, rows: UInt16) async throws { resizes.append((cols, rows)) }
        func currentStatus() async -> ClawShareSessionStatus { openStatus }
        func stopSession(reason: String) async -> ClawShareSessionStatus { stopped = true; return .stopped(reason: reason) }

        func sentInput() -> [Data] { sent }
        func appliedResizes() -> [(UInt16, UInt16)] { resizes }
        func wasStopped() -> Bool { stopped }
    }

    // MARK: - Tests

    func testStartOpensOnlyWhenInteractiveReadyAndSyncsSize() async {
        let client = ScriptClient()
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out, initialCols: 100, initialRows: 30)

        let state = await session.start()
        guard case .open = state else { return XCTFail("must open on interactiveReady, got \(state)") }
        let isOpen = await session.isOpen
        XCTAssertTrue(isOpen)
        // The initial terminal size is pushed to the remote PTY on open.
        let resizes = await client.appliedResizes()
        XCTAssertEqual(resizes.first?.0, 100)
        XCTAssertEqual(resizes.first?.1, 30)
    }

    func testStartRefusesWhenNotInteractive() async {
        // A client that only reaches `.streamReady` must NOT open a terminal.
        let client = ScriptClient(openStatus: .streamReady(sinceUnix: 2))
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out)
        let state = await session.start()
        guard case .failed = state else { return XCTFail("streamReady must not open a terminal, got \(state)") }
        let isOpen = await session.isOpen
        XCTAssertFalse(isOpen)
    }

    func testRemoteOutputIsFedToScreen() async {
        let client = ScriptClient()
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out)
        _ = await session.start()

        await client.pushOutput(Data("$ ".utf8))
        let first = await out.nextChunk()
        XCTAssertEqual(first, Data("$ ".utf8))
        await client.pushOutput(Data("hello\r\n".utf8))
        let second = await out.nextChunk()
        XCTAssertEqual(second, Data("hello\r\n".utf8))
    }

    func testKeyboardInputAndResizePropagate() async throws {
        let client = ScriptClient()
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out)
        _ = await session.start()

        try await session.send(Data("ls\n".utf8))
        try await session.resize(cols: 132, rows: 43)
        let sent = await client.sentInput()
        let resizes = await client.appliedResizes()
        XCTAssertEqual(sent, [Data("ls\n".utf8)])
        XCTAssertEqual(resizes.last?.0, 132)
        XCTAssertEqual(resizes.last?.1, 43)
    }

    func testStreamEndTransitionsToEndedAndNotifies() async {
        let client = ScriptClient()
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out)
        _ = await session.start()

        await client.pushEnd() // clean close / target exit
        // The sink is notified the session ended (recoverable).
        var reason: String?
        for _ in 0..<50 {
            reason = await out.ended()
            if reason != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(reason, "session-ended")
        let endState = await session.currentState()
        if case .ended = endState {} else {
            XCTFail("a closed stream must leave the session .ended, got \(endState)")
        }
        let isOpen = await session.isOpen
        XCTAssertFalse(isOpen, "an ended session must not be openable — no zombie")
    }

    func testStopIsIdempotentAndStopsClient() async {
        let client = ScriptClient()
        let out = RecordingOutput()
        let session = ClawShareTerminalSession(client: client, output: out)
        _ = await session.start()
        await session.stop(reason: "user")
        await session.stop(reason: "user")
        let stopped = await client.wasStopped()
        XCTAssertTrue(stopped)
        let endState = await session.currentState()
        if case .ended = endState {} else {
            XCTFail("stop must leave the session .ended")
        }
    }
}
