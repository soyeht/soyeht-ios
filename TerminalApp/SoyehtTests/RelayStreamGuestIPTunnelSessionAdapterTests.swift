import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import XCTest

final class RelayStreamGuestIPTunnelSessionAdapterTests: XCTestCase {
    func testDataFrameReturnsOnlyStructurallyValidPacket() async throws {
        let packet = Self.ipv6Packet()
        let native = AdapterFakeRelayStreamSession(frames: [
            RelayStreamGuestFrameRecord(
                kind: .data,
                data: packet,
                number: 0,
                text: ""
            ),
        ])
        let adapter = RelayStreamGuestIPTunnelSessionAdapter(
            session: RelayStreamGuestDataPlaneSession(native: native)
        )

        let received = try await adapter.receivePacket()
        XCTAssertEqual(received, packet)
    }

    func testPTYAndDuplicateHandshakeFramesFailClosed() async throws {
        for kind in [
            RelayStreamGuestFrameKind.window,
            .exitCode,
            .exitSignal,
            .exitLost,
            .health,
            .open,
        ] {
            let native = AdapterFakeRelayStreamSession(frames: [
                RelayStreamGuestFrameRecord(
                    kind: kind,
                    data: Data(),
                    number: 0,
                    text: ""
                ),
            ])
            let adapter = RelayStreamGuestIPTunnelSessionAdapter(
                session: RelayStreamGuestDataPlaneSession(native: native)
            )

            do {
                _ = try await adapter.receivePacket()
                XCTFail("expected non-packet frame rejection for \(kind)")
            } catch {
                XCTAssertEqual(
                    error as? RelayStreamGuestIPTunnelSessionError,
                    .nonPacketFrame
                )
            }
        }
    }

    func testOutboundMalformedPacketIsRejectedBeforeFFI() async throws {
        let native = AdapterFakeRelayStreamSession()
        let adapter = RelayStreamGuestIPTunnelSessionAdapter(
            session: RelayStreamGuestDataPlaneSession(native: native)
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.sendPacket(Data([0x60, 0x00]))
        )
        XCTAssertTrue(native.sentData.isEmpty)
    }

    private static func ipv6Packet() -> Data {
        var packet = Data(repeating: 0, count: 40)
        packet[0] = 0x60
        return packet
    }
}

private final class AdapterFakeRelayStreamSession: RelayStreamGuestSessionProtocol, @unchecked Sendable {
    private(set) var sentData: [Data] = []
    var frames: [RelayStreamGuestFrameRecord]

    init(frames: [RelayStreamGuestFrameRecord] = []) {
        self.frames = frames
    }

    func metadata() async -> RelayStreamGuestSessionMetadata {
        RelayStreamGuestSessionMetadata(
            meshIpv4: RelayStreamGuestIpv4Metadata(
                addr: "192.0.2.2",
                prefixLen: 24,
                peer: "192.0.2.3"
            ),
            meshIpv6: nil,
            mtu: 1_280,
            sessionId: "session-alpha"
        )
    }

    func readFrame() async throws -> RelayStreamGuestFrameRecord {
        guard !frames.isEmpty else {
            throw AdapterFakeRelayStreamError.noFrame
        }
        return frames.removeFirst()
    }

    func sendClose() async throws {}

    func sendData(data: Data) async throws {
        sentData.append(data)
    }

    func sendResize(cols _: UInt16, rows _: UInt16) async throws {}
}

private enum AdapterFakeRelayStreamError: Error {
    case noFrame
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
