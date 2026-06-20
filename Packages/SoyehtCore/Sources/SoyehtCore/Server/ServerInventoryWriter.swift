import Foundation

// MARK: - Server inventory writer
//
// Goal D inventory facade. This type centralizes the Core-owned writer surface
// without changing live v1 authority. Runtime adoption remains slice-gated:
// approved callers use v1 parity methods, while shadow/v2 helpers stay
// read-only.

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
