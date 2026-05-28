import Foundation
import NetworkExtension
import os.log
import SoyehtCore

/// SoyehtTunnel — iOS NetworkExtension Packet Tunnel Provider.
///
/// Runs as a separate extension process the system spawns when the
/// containing app calls `NETunnelProviderManager.startTunnel(...)`. The
/// extension is auto-entitled since 2016 (self-serve in Xcode Signing &
/// Capabilities — "Network Extensions" → "Packet Tunnel").
///
/// Lifecycle:
/// 1. Host app receives a `GuestCredential` from the claw-share claim
///    (see `ClawShareHTTPClient`).
/// 2. Host app creates an `NETunnelProviderProtocol`, attaches the
///    credential bytes in `providerConfiguration["credential_cbor"]`,
///    and calls `startTunnel`.
/// 3. iOS spawns this extension. `startTunnel` is invoked with the
///    options dict. We pull the credential, derive the peer npub from
///    `credential.tunnel`, and stand up the nvpn data plane.
/// 4. Packets that match the configured tunnel routes are delivered to
///    `packetFlow.readPackets(completionHandler:)`; we forward them
///    over the mesh. Inbound mesh packets are written back to
///    `packetFlow.writePackets`.
///
/// Slice scope: scaffold only. The actual nvpn data-plane wiring needs
/// the UniFFI bindings from `nostr-vpn-app-core` packaged as an
/// XCFramework — see `SoyehtTunnel/BUILD.md` for the build steps. This
/// file compiles + serves as the contract the build pipeline targets.

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.soyeht.tunnel", category: "provider")

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice("startTunnel invoked, options=\(options?.count ?? 0)")

        guard
            let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfig = protocolConfiguration.providerConfiguration
        else {
            log.error("missing provider configuration")
            completionHandler(SoyehtTunnelError.missingProviderConfig)
            return
        }

        // Decode the credential the host app handed us. The tunnel
        // handle's `peer_npub` tells us which mesh node to dial.
        let credential: GuestCredential
        do {
            credential = try decodeCredential(providerConfig)
        } catch {
            log.error("credential decode failed: \(error)")
            completionHandler(error)
            return
        }

        // Network settings claim. Use a link-local IPv6 placeholder
        // for the slice; production nvpn supplies a real ULA address
        // (fd00::/8) per the mesh routing policy.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "fd00::1")
        let ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6Settings
        settings.mtu = 1280

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            self.log.notice("tunnel up; peer=\(self.summarize(credential.tunnel))")

            // TODO(slice 9b): wire `nostr-vpn-app-core` via UniFFI.
            // Until then the tunnel is "up" from iOS's view but no
            // packets move. The host app sees `connected` state but
            // any TCP attempt over the mesh address will time out.
            self.startPacketLoopStub()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.notice("stopTunnel reason=\(String(describing: reason))")
        // TODO(slice 9b): shut down the nvpn runtime cleanly.
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Host app can poke the extension at runtime — credential
        // refresh, force-reconnect, status query.
        log.notice("handleAppMessage bytes=\(messageData.count)")
        completionHandler?(nil)
    }

    private func decodeCredential(_ config: [String: Any]) throws -> GuestCredential {
        guard let cborData = config["credential_cbor"] as? Data else {
            throw SoyehtTunnelError.missingCredential
        }
        return try ClawShareCodec.decodeCredential(cborData)
    }

    private func summarize(_ tunnel: ClawShareTunnelHandle) -> String {
        switch tunnel {
        case .loopback(let channel):
            return "loopback(\(channel))"
        case .fips(let peerNpub, let hint):
            return "fips(\(peerNpub.prefix(16))…, hint=\(hint ?? "-"))"
        }
    }

    private func startPacketLoopStub() {
        // Drain packets the OS hands us so the kernel doesn't back up.
        // Until the nvpn bindings land we silently discard them — the
        // tunnel is "up" but black-holes traffic. Visible in console
        // logs.
        packetFlow.readPacketObjects { [weak self] packets in
            guard let self else { return }
            self.log.debug("discarded \(packets.count) outbound packets (nvpn stub)")
            self.startPacketLoopStub()
        }
    }
}

enum SoyehtTunnelError: Error {
    case missingProviderConfig
    case missingCredential
}
