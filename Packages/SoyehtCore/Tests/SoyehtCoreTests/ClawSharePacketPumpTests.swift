import Foundation
import XCTest

@testable import SoyehtCore

/// Proves the packet pump moves a packet across the full path —
/// `packetFlow.readPackets` → `client.sendData` → (engine echo) →
/// `client.receiveData` → `packetFlow.writePackets` — using a fake
/// flow + a fake echoing client. This is the CI/simulator-safe stand-in
/// for the real Network Extension: the same pump runs in production with
/// `NEPacketTunnelFlowAdapter` + the real bridge.
final class ClawSharePacketPumpTests: XCTestCase {
    func testPacketEntersFlowCrossesClientAndReturnsViaFlow() async throws {
        let packet = Data([0x60, 0x00, 0x00, 0x00, 0xAB, 0xCD])
        let flow = FakePacketFlow(pending: [[packet]])
        let client = FakeEchoClient()
        let pump = ClawSharePacketPump(flow: flow, client: client)

        await pump.start()
        let written = await flow.firstWrittenPacket()
        await pump.stop()

        XCTAssertEqual(written, packet, "the packet must traverse flow→client→echo→client→flow")
    }

    /// A typed failure on the data-plane side ends the pump cleanly — no
    /// crash, no hang. (The flow keeps suspending; the inbound loop's
    /// `receiveData` throws and tears the pump down.)
    func testInboundFailureEndsPumpWithoutCrash() async throws {
        let flow = FakePacketFlow(pending: [])
        let client = FakeEchoClient()
        await client.failReceive()
        let pump = ClawSharePacketPump(flow: flow, client: client)

        await pump.start()
        // Should finish promptly because receiveData throws.
        await pump.waitUntilFinished()
        // Reaching here without hang/crash is the assertion.
    }
}

// MARK: - Fakes

/// Echoes: `sendData` enqueues, `receiveData` dequeues (suspending
/// until a packet is available). Models bridge + engine echo.
private actor FakeEchoClient: ClawShareDataPlaneClient {
    private var queue: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var receiveShouldFail = false

    func failReceive() { receiveShouldFail = true }

    func loadCredential(_ credentialCBOR: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus { .credentialReady }
    func startSession(endpoint: ClawShareDataPlaneEndpoint, sessionToken: Data) async throws -> ClawShareStartOutcome {
        ClawShareStartOutcome(meshIPv6: "fd00:c1aw::1", mtu: 1280, sessionId: "test", status: .awaitingFirstPacket)
    }
    func healthPing() async throws -> ClawShareSessionStatus { .connected(sinceUnix: 1) }
    func openStream() async throws -> ClawShareSessionStatus { .streamReady(sinceUnix: 2) }

    func sendData(_ packet: Data) async throws {
        if waiters.isEmpty {
            queue.append(packet)
        } else {
            waiters.removeFirst().resume(returning: packet)
        }
    }

    func receiveData() async throws -> Data {
        if receiveShouldFail { throw ClawShareDataPlaneError.noSession }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func currentStatus() async -> ClawShareSessionStatus { .streamReady(sinceUnix: 2) }
    func stopSession(reason: String) async -> ClawShareSessionStatus { .stopped(reason: reason) }
}

/// Hands out queued read-batches once, then idles (cancellable sleep — no
/// busy loop) so the pump's inbound loop has time to deliver the echo.
/// Captures written packets.
private actor FakePacketFlow: ClawSharePacketFlow {
    private var pending: [[Data]]
    private var written: [Data] = []
    private var writeWaiters: [CheckedContinuation<Data, Never>] = []

    init(pending: [[Data]]) { self.pending = pending }

    func readPackets() async -> [Data] {
        if !pending.isEmpty { return pending.removeFirst() }
        // Nothing more to send: idle until the pump is cancelled. The
        // sleep is cancellation-aware, so there is no busy loop.
        try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return []
    }

    func writePackets(_ packets: [Data]) async {
        written.append(contentsOf: packets)
        for packet in packets {
            if !writeWaiters.isEmpty {
                writeWaiters.removeFirst().resume(returning: packet)
            }
        }
    }

    func firstWrittenPacket() async -> Data {
        if let first = written.first { return first }
        return await withCheckedContinuation { writeWaiters.append($0) }
    }
}
