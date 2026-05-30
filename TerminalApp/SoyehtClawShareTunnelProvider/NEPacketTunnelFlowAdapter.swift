import Foundation
import NetworkExtension
import SoyehtCore

/// Adapts the real `NEPacketTunnelFlow` to the testable
/// `ClawSharePacketFlow` abstraction the `ClawSharePacketPump` drives.
/// The pump itself lives in SoyehtCore and is exercised in tests with a
/// fake flow; this adapter is the production binding.
final class NEPacketTunnelFlowAdapter: ClawSharePacketFlow, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow

    init(_ flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    /// Suspends until the OS hands us at least one outbound packet.
    /// `readPackets` always yields ≥1 packet, so the pump's outbound loop
    /// never busy-spins.
    func readPackets() async -> [Data] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Data], Never>) in
            flow.readPackets { packets, _ in
                cont.resume(returning: packets)
            }
        }
    }

    /// Write inbound packets back to the tunnel interface. All packets in
    /// this slice are IPv6 (the mesh address family).
    func writePackets(_ packets: [Data]) async {
        let protocols = packets.map { _ in NSNumber(value: AF_INET6) }
        flow.writePackets(packets, withProtocols: protocols)
    }
}
