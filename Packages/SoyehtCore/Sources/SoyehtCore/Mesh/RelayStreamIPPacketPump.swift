import Foundation

/// Address family carried alongside an IP packet at the Network Extension
/// boundary. Raw values intentionally match Darwin's `AF_INET` and `AF_INET6`.
public enum RelayStreamIPFamily: Int32, Codable, Sendable, Equatable {
    case ipv4 = 2
    case ipv6 = 30
}

/// A structurally validated IP packet.
///
/// Validation happens on both sides of the relay stream. The pump refuses to
/// forward arbitrary terminal bytes or a packet whose Network Extension family
/// metadata disagrees with its version nibble.
public struct RelayStreamIPPacket: Sendable, Equatable {
    public let data: Data
    public let family: RelayStreamIPFamily

    public init(data: Data, family: RelayStreamIPFamily? = nil) throws {
        guard let first = data.first else {
            throw RelayStreamIPPacketError.empty
        }

        let detectedFamily: RelayStreamIPFamily
        switch first >> 4 {
        case 4:
            guard data.count >= 20 else {
                throw RelayStreamIPPacketError.truncated
            }
            let headerLength = Int(first & 0x0F) * 4
            guard headerLength >= 20, data.count >= headerLength else {
                throw RelayStreamIPPacketError.invalidHeader
            }
            let totalLength = Int(data[2]) << 8 | Int(data[3])
            guard totalLength == data.count else {
                throw RelayStreamIPPacketError.invalidLength
            }
            detectedFamily = .ipv4
        case 6:
            guard data.count >= 40 else {
                throw RelayStreamIPPacketError.truncated
            }
            let payloadLength = Int(data[4]) << 8 | Int(data[5])
            guard payloadLength + 40 == data.count else {
                throw RelayStreamIPPacketError.invalidLength
            }
            detectedFamily = .ipv6
        default:
            throw RelayStreamIPPacketError.unsupportedVersion
        }

        if let family, family != detectedFamily {
            throw RelayStreamIPPacketError.familyMismatch
        }
        self.data = data
        self.family = detectedFamily
    }
}

public enum RelayStreamIPPacketError: Error, Sendable, Equatable {
    case empty
    case truncated
    case invalidHeader
    case invalidLength
    case unsupportedVersion
    case familyMismatch
}

/// Testable packet-IO seam implemented by `NEPacketTunnelFlow` in the
/// extension target.
public protocol RelayStreamIPPacketFlow: Sendable {
    func readPackets() async throws -> [RelayStreamIPPacket]
    func writePackets(_ packets: [RelayStreamIPPacket]) async throws
}

/// Packet-only relay-stream session. PTY resize/exit/window surfaces are
/// deliberately absent from this interface.
public protocol RelayStreamIPTunnelSession: Sendable {
    func sendPacket(_ packet: Data) async throws
    func receivePacket() async throws -> Data
    func close() async
}

public enum RelayStreamIPPacketPumpError: Error, Sendable, Equatable {
    case flowClosed
}

/// Bidirectional, backpressured packet pump.
///
/// One failing or closed side cancels the other side as a unit. Every packet is
/// validated before crossing the session boundary and again before being
/// written back to the utun flow.
public struct RelayStreamIPPacketPump: Sendable {
    private let flow: any RelayStreamIPPacketFlow
    private let session: any RelayStreamIPTunnelSession

    public init(
        flow: any RelayStreamIPPacketFlow,
        session: any RelayStreamIPTunnelSession
    ) {
        self.flow = flow
        self.session = session
    }

    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let packets = try await flow.readPackets()
                    guard !packets.isEmpty else {
                        throw RelayStreamIPPacketPumpError.flowClosed
                    }
                    for packet in packets {
                        try Task.checkCancellation()
                        let validated = try RelayStreamIPPacket(
                            data: packet.data,
                            family: packet.family
                        )
                        try await session.sendPacket(validated.data)
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    let data = try await session.receivePacket()
                    let packet = try RelayStreamIPPacket(data: data)
                    try await flow.writePackets([packet])
                }
            }

            do {
                _ = try await group.next()
                group.cancelAll()
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
