import Foundation
import NetworkExtension

/// Packet-tunnel extension boundary for the owner mesh transport.
///
/// This scaffold deliberately has no route, peer, or data-plane behavior. It
/// fails closed until the authenticated mesh configuration and native tunnel
/// pump are introduced in later, separately reviewed slices.
final class SoyehtClawShareTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(TunnelProviderError.notConfigured)
    }

    override func stopTunnel(
        with _: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

private enum TunnelProviderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "Owner mesh tunnel is not configured."
    }
}
