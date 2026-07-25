import Foundation
import Testing

@testable import SoyehtCore

@Suite("Relay-stream IP packet pump")
struct RelayStreamIPPacketPumpTests {
    @Test func packetValidationPinsVersionLengthAndFamily() throws {
        let ipv4 = Self.ipv4Packet(payload: [0xAA, 0xBB])
        let ipv6 = Self.ipv6Packet(payload: [0xCC])

        #expect(try RelayStreamIPPacket(data: ipv4).family == .ipv4)
        #expect(try RelayStreamIPPacket(data: ipv6).family == .ipv6)
        #expect(throws: RelayStreamIPPacketError.familyMismatch) {
            try RelayStreamIPPacket(data: ipv4, family: .ipv6)
        }
        #expect(throws: RelayStreamIPPacketError.invalidLength) {
            try RelayStreamIPPacket(data: ipv4 + Data([0x00]))
        }
        #expect(throws: RelayStreamIPPacketError.unsupportedVersion) {
            try RelayStreamIPPacket(data: Data(repeating: 0x10, count: 20))
        }
    }

    @Test func pumpMovesIPv4AndIPv6InBothDirections() async throws {
        let outbound4 = Self.ipv4Packet(payload: [0x01])
        let outbound6 = Self.ipv6Packet(payload: [0x02, 0x03])
        let inbound4 = Self.ipv4Packet(payload: [0x04])
        let inbound6 = Self.ipv6Packet(payload: [0x05, 0x06])
        let flow = PacketFlowFake(
            outbound: [[
                try RelayStreamIPPacket(data: outbound4),
                try RelayStreamIPPacket(data: outbound6),
            ]]
        )
        let session = PacketSessionFake(inbound: [inbound4, inbound6])
        let pump = RelayStreamIPPacketPump(flow: flow, session: session)

        let task = Task { try await pump.run() }
        try await session.waitForSentPacketCount(2)
        try await flow.waitForWrittenPacketCount(2)
        task.cancel()
        _ = await task.result

        #expect(await session.sentPackets == [outbound4, outbound6])
        #expect(await flow.writtenPackets.map(\.data) == [inbound4, inbound6])
        #expect(await flow.writtenPackets.map(\.family) == [.ipv4, .ipv6])
    }

    @Test func malformedInboundPacketFailsClosed() async throws {
        let flow = PacketFlowFake(outbound: [])
        let session = PacketSessionFake(inbound: [Data([0x70])])
        let pump = RelayStreamIPPacketPump(flow: flow, session: session)

        do {
            try await pump.run()
            Issue.record("malformed packet unexpectedly crossed the pump")
        } catch {
            #expect(error as? RelayStreamIPPacketError == .unsupportedVersion)
        }
        #expect(await flow.writtenPackets.isEmpty)
    }

    private static func ipv4Packet(payload: [UInt8]) -> Data {
        let totalLength = 20 + payload.count
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x45
        bytes[2] = UInt8(totalLength >> 8)
        bytes[3] = UInt8(totalLength & 0xFF)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    private static func ipv6Packet(payload: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = 0x60
        bytes[4] = UInt8(payload.count >> 8)
        bytes[5] = UInt8(payload.count & 0xFF)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }
}

private actor PacketFlowFake: RelayStreamIPPacketFlow {
    private var outbound: [[RelayStreamIPPacket]]
    private(set) var writtenPackets: [RelayStreamIPPacket] = []

    init(outbound: [[RelayStreamIPPacket]]) {
        self.outbound = outbound
    }

    func readPackets() async throws -> [RelayStreamIPPacket] {
        if !outbound.isEmpty {
            return outbound.removeFirst()
        }
        try await Task.sleep(for: .seconds(30))
        return []
    }

    func writePackets(_ packets: [RelayStreamIPPacket]) async throws {
        writtenPackets.append(contentsOf: packets)
    }

    func waitForWrittenPacketCount(_ count: Int) async throws {
        while writtenPackets.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor PacketSessionFake: RelayStreamIPTunnelSession {
    private var inbound: [Data]
    private(set) var sentPackets: [Data] = []

    init(inbound: [Data]) {
        self.inbound = inbound
    }

    func sendPacket(_ packet: Data) async throws {
        sentPackets.append(packet)
    }

    func receivePacket() async throws -> Data {
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    func close() async {}

    func waitForSentPacketCount(_ count: Int) async throws {
        while sentPackets.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
