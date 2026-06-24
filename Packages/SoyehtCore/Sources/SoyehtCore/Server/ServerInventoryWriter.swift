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

    /// D3b: gates the v2-projected READ path. Default OFF — D3b only dual-writes the
    /// v2 mirror and wires the gated read plumbing; D3c flips this on (with an
    /// explicit GO) after a clean dry-run. With it OFF, `loadCanonical` is identical
    /// to `load()` (v1), so D3b is a pure additive, read-behavior-preserving slice.
    private let v2ReadEnabled: Bool

    /// D3b: supplies the legacy projections (with per-id credential presence) used to
    /// build the dual-written v2 mirror, so the mirror carries the SAME credential /
    /// provenance refs D1/D2 protect — not just a shape-equivalent v1 projection.
    /// Without it, a canonical-only mutation (status/lastSeen) would persist a
    /// credential-LESS v2 that still passes `projected == v1`. The boundary
    /// (`ServerRegistry`) injects this; Core never imports the legacy stores.
    private let v2MirrorProjectionProvider: @Sendable () -> [ServerStoreShadowProjection]

    public init(
        store: ServerStore = ServerStore(),
        v2ReadEnabled: Bool = false,
        v2MirrorProjectionProvider: @escaping @Sendable () -> [ServerStoreShadowProjection] = { [] }
    ) {
        self.store = store
        self.v2ReadEnabled = v2ReadEnabled
        self.v2MirrorProjectionProvider = v2MirrorProjectionProvider
    }

    public func load() -> [Server] {
        store.load()
    }

    @discardableResult
    public func upsertCanonical(_ server: Server) -> [Server] {
        let result = store.upsert(server)
        mirrorToV2()
        return result
    }

    @discardableResult
    public func upsertLegacyProjection(_ server: Server) -> [Server] {
        let result = store.upsertLegacyProjection(server)
        mirrorToV2()
        return result
    }

    @discardableResult
    public func remove(id: String) -> [Server] {
        let result = store.remove(id: id)
        mirrorToV2()
        return result
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
        mirrorToV2()
    }

    @discardableResult
    public func reconcileLegacy(
        seed: [Server],
        secretOwnedIDs: Set<String> = [],
        tokenOwnedIDs: Set<String> = [],
        credentialRekeyer: ServerStore.CredentialRekeyer? = nil
    ) -> [Server] {
        let result = store.reconcile(
            with: seed, secretOwnedIDs: secretOwnedIDs,
            tokenOwnedIDs: tokenOwnedIDs, credentialRekeyer: credentialRekeyer
        )
        mirrorToV2()
        return result
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

    /// D3b dual-write: after every v1 mutation, re-derive the v2 envelope from the
    /// post-write v1 state and persist it. v1 stays the primary/rollback path; a
    /// `saveV2Envelope` failure is swallowed by the store (logged) and NEVER masks
    /// the v1 mutation. The v2 mirror is only ever READ behind `loadCanonical`.
    private func mirrorToV2() {
        // Derive the mirror with the REAL legacy projections so the persisted v2
        // carries pairingSecret / sessionToken refs + provenance — a canonical-only
        // mutation must never overwrite a good v2 with a credential-less envelope.
        store.saveV2Envelope(makeV2Envelope(legacyProjections: v2MirrorProjectionProvider()))
    }

    /// D3b gated read (default OFF). Returns the v2-projected servers ONLY when ALL
    /// hold: the explicit `v2ReadEnabled` flag, the D3a dry-run gate reads ready, and
    /// the loaded v2 projects field-equivalent to the current v1 (runtime staleness
    /// guard — a failed dual-write can never serve a stale v2). Otherwise falls back
    /// to v1. No id/host/token is logged. D3c is where a caller constructs the writer
    /// with `v2ReadEnabled: true` after an explicit clean-dry-run GO.
    public func loadCanonical(
        legacyProjectionsForGate: [ServerStoreShadowProjection] = [],
        activeServerID: String? = nil
    ) -> [Server] {
        let v1 = store.load()
        guard v2ReadEnabled else { return v1 }
        let gate = migrationDryRunReadiness(
            legacyProjections: legacyProjectionsForGate, activeServerID: activeServerID
        )
        guard gate.isReadyToFlip, let envelope = store.loadV2Envelope() else { return v1 }
        let projected = projectV1Servers(from: envelope)
        guard Set(projected) == Set(v1) else { return v1 }  // runtime equivalence / staleness guard
        return projected
    }
}
