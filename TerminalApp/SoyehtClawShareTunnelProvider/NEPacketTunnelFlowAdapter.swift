import Foundation
import NetworkExtension
import SoyehtCore

/// Production binding between NetworkExtension packet IO and the independently
/// tested SoyehtCore packet pump.
final class NEPacketTunnelFlowAdapter: RelayStreamIPPacketFlow, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow

    init(_ flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func readPackets() async throws -> [RelayStreamIPPacket] {
        try await withCheckedThrowingContinuation { continuation in
            flow.readPackets { packets, protocols in
                guard packets.count == protocols.count else {
                    continuation.resume(throwing: NEPacketTunnelFlowAdapterError.familyCountMismatch)
                    return
                }

                do {
                    let validated = try zip(packets, protocols).map { data, protocolNumber in
                        guard let family = RelayStreamIPFamily(
                            rawValue: protocolNumber.int32Value
                        ) else {
                            throw NEPacketTunnelFlowAdapterError.unsupportedFamily
                        }
                        return try RelayStreamIPPacket(data: data, family: family)
                    }
                    continuation.resume(returning: validated)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func writePackets(_ packets: [RelayStreamIPPacket]) async throws {
        let accepted = flow.writePackets(
            packets.map(\.data),
            withProtocols: packets.map { NSNumber(value: $0.family.rawValue) }
        )
        guard accepted else {
            throw NEPacketTunnelFlowAdapterError.writeRejected
        }
    }
}

enum NEPacketTunnelFlowAdapterError: Error, Sendable, Equatable {
    case familyCountMismatch
    case unsupportedFamily
    case writeRejected
}
