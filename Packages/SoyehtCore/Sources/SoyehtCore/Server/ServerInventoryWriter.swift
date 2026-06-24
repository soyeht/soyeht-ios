import Foundation

// MARK: - Server inventory writer
//
// Goal D inventory facade. This type centralizes the Core-owned writer surface
// without changing live v1 authority. Runtime adoption remains slice-gated:
// approved callers use v1 parity methods, while shadow/v2 helpers stay
// read-only.

/// D3a: the result of the migration dry-run readiness gate. The v2->live flip
/// (D3b) is allowed only when `isReadyToFlip` is true.
public struct MigrationReadiness: Equatable, Sendable {
    /// No shadow-compare mismatches — the v2 projection faithfully and credential-
    /// safely matches the legacy stores (the precondition for flipping to live).
    public let shadowClean: Bool
    /// Whether the one-shot migration completed (sentinel set). D2 leaves it unset
    /// when a credential re-key failed closed, so the store is not yet trustworthy.
    public let migrationCompleted: Bool
    /// The neutral mismatch categories blocking readiness (no ids/hosts/tokens).
    public let blockingCategories: [ServerStoreShadowMismatch]

    public init(
        shadowClean: Bool,
        migrationCompleted: Bool,
        blockingCategories: [ServerStoreShadowMismatch]
    ) {
        self.shadowClean = shadowClean
        self.migrationCompleted = migrationCompleted
        self.blockingCategories = blockingCategories
    }

    /// Go/no-go: ready to flip ONLY when the shadow is clean AND migration completed.
    public var isReadyToFlip: Bool { shadowClean && migrationCompleted }
}

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
            seed: seed, secretOwnedIDs: secretOwnedIDs,
            tokenOwnedIDs: tokenOwnedIDs, credentialRekeyer: credentialRekeyer
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
            with: seed, secretOwnedIDs: secretOwnedIDs,
            tokenOwnedIDs: tokenOwnedIDs, credentialRekeyer: credentialRekeyer
        )
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

    /// D3a: the dry-run go/no-go gate that MUST read `isReadyToFlip == true` before
    /// the v2->live writer flip (D3b). It is READ-ONLY — it runs the shadow compare
    /// and reports readiness; it does not flip anything. A flip can only be allowed
    /// when the v2 projection has ZERO shadow mismatches (especially the D1
    /// credential-orphan categories) AND the one-shot migration completed (D2 leaves
    /// the sentinel unset when a credential re-key failed closed). Reasons are
    /// neutral category counts — no ids, hosts, or tokens.
    public func migrationDryRunReadiness(
        legacyProjections: [ServerStoreShadowProjection],
        activeServerID: String? = nil
    ) -> MigrationReadiness {
        let report = shadowCompare(legacyProjections: legacyProjections, activeServerID: activeServerID)
        return MigrationReadiness(
            shadowClean: report.isClean,
            migrationCompleted: store.isMigrated,
            blockingCategories: report.mismatches.map(\.category)
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
