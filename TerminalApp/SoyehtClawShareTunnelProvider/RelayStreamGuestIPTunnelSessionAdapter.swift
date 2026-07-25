import Foundation
import RelayStreamGuestFFI
import SoyehtCore

/// Narrows the relay-stream frame protocol to the packet-only interface used
/// by the NetworkExtension pump. PTY control frames fail closed.
struct RelayStreamGuestIPTunnelSessionAdapter: RelayStreamIPTunnelSession {
    let session: RelayStreamGuestDataPlaneSession

    func sendPacket(_ packet: Data) async throws {
        _ = try RelayStreamIPPacket(data: packet)
        try await session.send(data: packet)
    }

    func receivePacket() async throws -> Data {
        while !Task.isCancelled {
            let frame = try await session.nextFrame()
            switch frame.kind {
            case .data:
                return try RelayStreamIPPacket(data: frame.data).data
            case .close:
                throw RelayStreamGuestIPTunnelSessionError.closed
            case .error:
                throw RelayStreamGuestIPTunnelSessionError.remoteRejected
            case .window, .exitCode, .exitSignal, .exitLost, .health, .open:
                throw RelayStreamGuestIPTunnelSessionError.nonPacketFrame
            }
        }
        throw CancellationError()
    }

    func close() async {
        try? await session.close()
    }
}

enum RelayStreamGuestIPTunnelSessionError: Error, Sendable, Equatable {
    case closed
    case remoteRejected
    case nonPacketFrame
}
