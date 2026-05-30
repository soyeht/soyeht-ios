import XCTest
import SoyehtCore
@testable import Soyeht

/// Binding contract for `ClawShareTerminalView` ↔ `ClawShareTerminalSession`.
///
/// Drives the REAL view against a fake data-plane client (no engine/PTY):
/// keyboard input from the view reaches the client's stdin, a view resize is
/// emitted as a resize to the client, the live gate fires on
/// `.interactiveReady`, and a stream end removes the open state without a
/// zombie. The remote-output→screen path is covered by the CI-gated driver
/// test (`ClawShareTerminalSessionTests`) plus the documented device smoke;
/// reading SwiftTerm's private buffer is intentionally not asserted here.
///
/// Not run in the iOS CI build (which compiles the app, not the app unit
/// tests); reproducible locally via `xcodebuild test -scheme Soyeht`.
@MainActor
final class ClawShareTerminalViewTests: XCTestCase {
    /// Controllable fake: open reaches interactiveReady, records stdin +
    /// resizes, and lets the test end the stream.
    private actor FakeClient: ClawShareDataPlaneClient {
        private var recvWaiters: [CheckedContinuation<Data, Error>] = []
        private var outbox: [Result<Data, Error>] = []
        private(set) var sent: [Data] = []
        private(set) var resizes: [(UInt16, UInt16)] = []

        func pushEnd() {
            if recvWaiters.isEmpty { outbox.append(.failure(ClawShareDataPlaneError.noSession)) }
            else { recvWaiters.removeFirst().resume(throwing: ClawShareDataPlaneError.noSession) }
        }

        func loadCredential(_ c: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus { .credentialReady }
        func startSession(endpoint: ClawShareDataPlaneEndpoint, sessionToken: Data) async throws -> ClawShareStartOutcome {
            ClawShareStartOutcome(meshIPv6: "fd00:c1aw::1", mtu: 1280, sessionId: "t", status: .awaitingFirstPacket)
        }
        func healthPing() async throws -> ClawShareSessionStatus { .connected(sinceUnix: 1) }
        func openStream() async throws -> ClawShareSessionStatus { .interactiveReady(sinceUnix: 2) }
        func sendData(_ packet: Data) async throws { sent.append(packet) }
        func receiveData() async throws -> Data {
            if !outbox.isEmpty { return try outbox.removeFirst().get() }
            return try await withCheckedThrowingContinuation { recvWaiters.append($0) }
        }
        func resize(cols: UInt16, rows: UInt16) async throws { resizes.append((cols, rows)) }
        func currentStatus() async -> ClawShareSessionStatus { .interactiveReady(sinceUnix: 2) }
        func stopSession(reason: String) async -> ClawShareSessionStatus { .stopped(reason: reason) }

        func sentInput() -> [Data] { sent }
        func appliedResizes() -> [(UInt16, UInt16)] { resizes }
    }

    private func makeReadyView(_ client: FakeClient) async -> ClawShareTerminalView {
        let view = ClawShareTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let ready = expectation(description: "interactiveReady")
        view.onInteractiveReady = { ready.fulfill() }
        view.attach(client: client)
        await fulfillment(of: [ready], timeout: 5)
        return view
    }

    func testInteractiveReadyGateFires() async {
        let client = FakeClient()
        _ = await makeReadyView(client)
        // Reaching makeReadyView means onInteractiveReady fired (the only
        // point the host reveals the terminal).
    }

    func testKeyboardInputReachesClientStdin() async throws {
        let client = FakeClient()
        let view = await makeReadyView(client)
        view.send(source: view, data: ArraySlice("ls\n".utf8))
        // Let the detached send Task run.
        try await Task.sleep(nanoseconds: 200_000_000)
        let sent = await client.sentInput()
        XCTAssertEqual(sent, [Data("ls\n".utf8)], "keyboard input must reach the client's stdin")
    }

    func testViewResizeEmitsResizeToClient() async throws {
        let client = FakeClient()
        let view = await makeReadyView(client)
        view.sizeChanged(source: view, newCols: 120, newRows: 40)
        try await Task.sleep(nanoseconds: 200_000_000)
        let resizes = await client.appliedResizes()
        XCTAssertEqual(resizes.last?.0, 120)
        XCTAssertEqual(resizes.last?.1, 40)
    }

    func testStreamEndRemovesOpenState() async {
        let client = FakeClient()
        let view = await makeReadyView(client)
        let ended = expectation(description: "sessionEnded")
        view.onSessionEnded = { _ in ended.fulfill() }
        await client.pushEnd()
        await fulfillment(of: [ended], timeout: 5)
        // onSessionEnded fired → the host removes the open affordance; no zombie.
    }
}
