import Foundation
import Darwin
import SoyehtCore
import SwiftUI
import os

private let registryLogger = Logger(subsystem: "com.soyeht.mobile", category: "presence")

/// Orchestrates one `MacPresenceClient` per paired Mac. Bootstrapped in
/// AppDelegate, observes PairedMacsStore so newly paired Macs get a client
/// and revoked Macs get disconnected.
///
/// ObservableObject so SwiftUI home list can bind to the `clients` array.
@MainActor
final class PairedMacRegistry: ObservableObject {
    typealias ClientFactory = (
        _ mac: PairedMac,
        _ secret: Data,
        _ deviceID: UUID,
        _ endpoint: MacPresenceClient.Endpoint?
    ) -> MacPresenceClient

    static let shared = PairedMacRegistry()

    @Published private(set) var clients: [UUID: MacPresenceClient] = [:]

    /// Callback emitted when a Mac pushes `open_pane_request` — SSHLoginView
    /// observes this to navigate to the pane.
    var onOpenPaneRequest: ((_ macID: UUID, _ paneID: String) -> Void)?

    private let store: PairedMacsStore
    private let clientFactory: ClientFactory
    private let tailnetAddressProvider: () -> String?
    private let localNetworkProvider: () -> Bool

    init(
        store: PairedMacsStore? = nil,
        tailnetAddressProvider: @escaping () -> String? = { TailnetAddressResolver.currentTailnetIPv4() },
        localNetworkProvider: @escaping () -> Bool = { DeviceNetworkState.hasActiveWiFiIPv4() },
        clientFactory: ClientFactory? = nil
    ) {
        self.store = store ?? .shared
        self.tailnetAddressProvider = tailnetAddressProvider
        self.localNetworkProvider = localNetworkProvider
        self.clientFactory = clientFactory ?? { mac, secret, deviceID, endpoint in
            MacPresenceClient(
                macID: mac.macID,
                deviceID: deviceID,
                secret: secret,
                endpoint: endpoint,
                displayName: mac.name
            )
        }
    }

    /// Called by AppDelegate on launch. Connects every paired Mac with stored
    /// endpoints.
    func bootstrap() {
        store.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.reconcileClients() }
        }
        reconcileClients()
    }

    /// Diff between `PairedMacsStore.macs` and `clients`: create for new, tear
    /// down for removed. Called on bootstrap and on any change event.
    func reconcileClients() {
        let wantedIDs = Set(store.macs.map(\.macID))
        let currentIDs = Set(clients.keys)

        // Tear down removed.
        for macID in currentIDs.subtracting(wantedIDs) {
            if let client = clients.removeValue(forKey: macID) {
                client.disconnect()
                registryLogger.log("registry_client_removed mac_id=\(macID.uuidString, privacy: .public)")
            }
        }

        // Add / refresh endpoints for existing.
        for mac in store.macs {
            let existing = clients[mac.macID]
            let endpoint = buildEndpoint(for: mac)
            if let existing {
                if let endpoint {
                    existing.updateEndpoint(endpoint)
                    existing.connect()
                }
                continue
            }
            guard let secret = store.secret(for: mac.macID) else {
                registryLogger.error("registry_missing_secret mac_id=\(mac.macID.uuidString, privacy: .public)")
                continue
            }
            let client = clientFactory(mac, secret, store.deviceID, endpoint)
            client.onOpenPaneRequest = { [weak self] paneID in
                self?.onOpenPaneRequest?(mac.macID, paneID)
            }
            clients[mac.macID] = client
            client.connect()
            registryLogger.log("registry_client_added mac_id=\(mac.macID.uuidString, privacy: .public)")
        }
    }

    /// Handy accessor for views.
    func client(for macID: UUID) -> MacPresenceClient? {
        clients[macID]
    }

    private func buildEndpoint(for mac: PairedMac) -> MacPresenceClient.Endpoint? {
        guard let host = mac.lastHost,
              let presencePort = mac.presencePort,
              let attachPort = mac.attachPort else {
            return nil
        }
        // `lastHost` stored during Fase 1 can include "host:port". EndpointPolicy
        // owns host parsing so IPv6, bracketed hosts, and ports stay consistent.
        let bareHost = EndpointPolicy.normalizedHost(from: host) ?? host
        let labelCandidates = EndpointPolicy.hostLabelCandidates(from: [
            mac.name,
            mac.displayName,
            bareHost
        ])
        let magicDNSCandidates = labelCandidates
        let localCandidates = labelCandidates.map { "\($0).local" }
        let resolved = EndpointPolicy.resolveServerEndpoint(
            bareHost: bareHost,
            localLabels: localCandidates,
            magicDNSLabels: magicDNSCandidates,
            localNetworkActive: localNetworkProvider(),
            tailnetActive: tailnetAddressProvider() != nil,
            presencePort: presencePort,
            attachPort: attachPort
        )
        guard let resolvedPresencePort = resolved.presencePort,
              let resolvedAttachPort = resolved.attachPort else {
            return nil
        }

        return MacPresenceClient.Endpoint(
            host: resolved.orderedHosts.first ?? bareHost,
            presencePort: resolvedPresencePort,
            attachPort: resolvedAttachPort,
            hostCandidates: resolved.orderedHosts
        )
    }
}

enum DeviceNetworkState {
    static func hasActiveWiFiIPv4() -> Bool {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return false
        }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sockaddrPtr = entry.pointee.ifa_addr else { continue }
            guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            if name == "en0" {
                return true
            }
        }
        return false
    }
}
