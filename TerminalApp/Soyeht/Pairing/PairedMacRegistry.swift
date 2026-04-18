import Foundation
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
    static let shared = PairedMacRegistry()

    @Published private(set) var clients: [UUID: MacPresenceClient] = [:]

    /// Callback emitted when a Mac pushes `open_pane_request` — SSHLoginView
    /// observes this to navigate to the pane.
    var onOpenPaneRequest: ((_ macID: UUID, _ paneID: String) -> Void)?

    private init() {}

    /// Called by AppDelegate on launch. Connects every paired Mac with stored
    /// endpoints.
    func bootstrap() {
        PairedMacsStore.shared.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.reconcileClients() }
        }
        reconcileClients()
    }

    /// Diff between `PairedMacsStore.macs` and `clients`: create for new, tear
    /// down for removed. Called on bootstrap and on any change event.
    func reconcileClients() {
        let wantedIDs = Set(PairedMacsStore.shared.macs.map(\.macID))
        let currentIDs = Set(clients.keys)

        // Tear down removed.
        for macID in currentIDs.subtracting(wantedIDs) {
            if let client = clients.removeValue(forKey: macID) {
                client.disconnect()
                registryLogger.log("registry_client_removed mac_id=\(macID.uuidString, privacy: .public)")
            }
        }

        // Add / refresh endpoints for existing.
        for mac in PairedMacsStore.shared.macs {
            let existing = clients[mac.macID]
            let endpoint = Self.buildEndpoint(for: mac)
            if let existing {
                if let endpoint { existing.updateEndpoint(endpoint) }
                continue
            }
            guard let secret = PairedMacsStore.shared.secret(for: mac.macID) else {
                registryLogger.error("registry_missing_secret mac_id=\(mac.macID.uuidString, privacy: .public)")
                continue
            }
            let client = MacPresenceClient(
                macID: mac.macID,
                deviceID: PairedMacsStore.shared.deviceID,
                secret: secret,
                endpoint: endpoint,
                displayName: mac.name
            )
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

    private static func buildEndpoint(for mac: PairedMac) -> MacPresenceClient.Endpoint? {
        guard let host = mac.lastHost,
              let presencePort = mac.presencePort,
              let attachPort = mac.attachPort else {
            return nil
        }
        // `lastHost` stored during Fase 1 includes "host:port". Strip any port
        // suffix so the base host (IPv4 / Tailscale / DNS name) is reused.
        let bareHost: String
        if let colon = host.lastIndex(of: ":"), !host.contains("::") {
            bareHost = String(host[..<colon])
        } else {
            bareHost = host
        }
        return MacPresenceClient.Endpoint(host: bareHost, presencePort: presencePort, attachPort: attachPort)
    }
}
