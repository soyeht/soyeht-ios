import Foundation

// MARK: - Server inventory writer
//
// Centralized facade for the shipped v1 ServerStore authority. Runtime adoption
// remains intentionally narrow: approved adapters use these parity methods while
// ServerStore keeps the persistence and migration semantics.

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

    public func migrateLegacyIfNeeded(
        seed: [Server],
        secretOwnedIDs: Set<String> = [],
        tokenOwnedIDs: Set<String> = [],
        credentialRekeyer: ServerStore.CredentialRekeyer? = nil
    ) {
        store.migrateLegacyIfNeeded(
            seed: seed,
            secretOwnedIDs: secretOwnedIDs,
            tokenOwnedIDs: tokenOwnedIDs,
            credentialRekeyer: credentialRekeyer
        )
    }

    @discardableResult
    public func reconcileLegacy(
        seed: [Server],
        secretOwnedIDs: Set<String> = [],
        tokenOwnedIDs: Set<String> = [],
        credentialRekeyer: ServerStore.CredentialRekeyer? = nil
    ) -> [Server] {
        store.reconcile(
            with: seed,
            secretOwnedIDs: secretOwnedIDs,
            tokenOwnedIDs: tokenOwnedIDs,
            credentialRekeyer: credentialRekeyer
        )
    }
}
