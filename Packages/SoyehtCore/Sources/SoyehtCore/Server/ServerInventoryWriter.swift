import Foundation

// MARK: - Server inventory writer
//
// Goal D D3 facade shell. This type centralizes the Core-owned inventory writer
// surface without changing runtime authority. Existing app call sites are not
// wired to this type in D3; tests pin parity with the current ServerStore v1
// behavior before any later adoption slice can move callers behind it.

public struct ServerInventoryWriter: Sendable {
    private let store: ServerStore

    public init(store: ServerStore = ServerStore()) {
        self.store = store
    }

    public func load() -> [Server] {
        store.load()
    }

    @discardableResult
    public func upsertCanonical(_ server: Server) -> [Server] {
        store.upsert(server)
    }

    @discardableResult
    public func upsertLegacyProjection(_ server: Server) -> [Server] {
        store.upsertLegacyProjection(server)
    }

    @discardableResult
    public func remove(id: String) -> [Server] {
        store.remove(id: id)
    }

    public func migrateLegacyIfNeeded(seed: [Server], secretOwnedIDs: Set<String> = []) {
        store.migrateLegacyIfNeeded(seed: seed, secretOwnedIDs: secretOwnedIDs)
    }

    @discardableResult
    public func reconcileLegacy(seed: [Server], secretOwnedIDs: Set<String> = []) -> [Server] {
        store.reconcile(with: seed, secretOwnedIDs: secretOwnedIDs)
    }

    public func shadowCompare(
        legacyProjections: [ServerStoreShadowProjection],
        activeServerID: String? = nil
    ) -> ServerStoreShadowReport {
        ServerStoreShadowComparer.compare(
            canonicalServers: store.load(),
            legacyProjections: legacyProjections,
            activeServerID: activeServerID
        )
    }

    public func makeV2Envelope(
        legacyProjections: [ServerStoreShadowProjection] = [],
        installProfile: SoyehtInstallProfile = .current
    ) -> ServerStoreV2Envelope {
        ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: store.load(),
            legacyProjections: legacyProjections,
            installProfile: installProfile
        )
    }

    public func projectV1Servers(from envelope: ServerStoreV2Envelope) -> [Server] {
        ServerStoreV2Migrator.projectV1Servers(from: envelope)
    }
}
