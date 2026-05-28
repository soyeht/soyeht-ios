import Foundation
import os

/// The OS tunnel interface's packet IO, abstracted so the pump loop is
/// testable without a live Network Extension (CI / simulator can't run a
/// real `NEPacketTunnelProvider`). The extension adapts
/// `NEPacketTunnelFlow` to this; tests use a fake.
public protocol ClawSharePacketFlow: Sendable {
    /// Read the next batch of outbound packets from the tunnel interface.
    /// Suspends until at least one packet is available. Returning an
    /// empty array signals the flow is closed and the pump should stop
    /// (the real `NEPacketTunnelFlow` always yields ≥1 packet, so this is
    /// only hit on teardown / in tests — it prevents a busy loop).
    func readPackets() async -> [Data]

    /// Write inbound packets to the tunnel interface.
    func writePackets(_ packets: [Data]) async
}

/// Pumps packets between the OS tunnel interface (`ClawSharePacketFlow`)
/// and the data-plane tunnel (`ClawShareDataPlaneClient`). Two concurrent
/// loops:
/// - outbound: `flow.readPackets()` → `client.sendPacket`
/// - inbound:  `client.receivePacket()` → `flow.writePackets`
///
/// Both loops `await` their source, so there is no busy loop, and reading
/// one batch at a time before sending provides natural backpressure. A
/// typed failure on either side, an empty read (closed flow), or
/// cancellation ends the pump cleanly.
public actor ClawSharePacketPump {
    private let flow: any ClawSharePacketFlow
    private let client: any ClawShareDataPlaneClient
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "packet-pump")

    public init(flow: any ClawSharePacketFlow, client: any ClawShareDataPlaneClient) {
        self.flow = flow
        self.client = client
    }

    /// Start the pump. Idempotent.
    public func start() {
        guard task == nil else { return }
        let flow = self.flow
        let client = self.client
        let logger = self.logger
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                // Outbound: OS tunnel → data plane.
                group.addTask {
                    while !Task.isCancelled {
                        let packets = await flow.readPackets()
                        if packets.isEmpty { break } // flow closed
                        for packet in packets {
                            do {
                                try await client.sendPacket(packet)
                            } catch {
                                logger.error("pump_outbound_failed err=\(String(describing: error), privacy: .public)")
                                return
                            }
                        }
                    }
                }
                // Inbound: data plane → OS tunnel.
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            let packet = try await client.receivePacket()
                            await flow.writePackets([packet])
                        } catch {
                            logger.error("pump_inbound_failed err=\(String(describing: error), privacy: .public)")
                            return
                        }
                    }
                }
                // When either loop returns, cancel the other so the pump
                // tears down as a unit rather than leaking a half-loop.
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// Stop the pump. Idempotent. Cancels both loops.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Await pump completion (both loops ended). For tests / teardown.
    public func waitUntilFinished() async {
        await task?.value
    }
}
