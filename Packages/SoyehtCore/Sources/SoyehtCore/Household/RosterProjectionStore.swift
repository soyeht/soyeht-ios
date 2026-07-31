import Foundation
import Security

public enum RosterProjectionStoreError: Error, Equatable, Sendable {
    /// The secure store refused the write. Nothing was published in memory.
    case persistenceFailed
    /// `commitCurrent` was called before any QR anchor was seeded. A current
    /// state has no meaning without the anchor that rooted it.
    case anchorMissing
    /// The supplied evidence bytes / signer cert did not survive re-derivation
    /// through the existing authority path.
    case evidenceUnusable
    /// Candidate `floor_secs` is older than the persisted one.
    case floorRollback
    /// The persisted state is a terminal fork and the candidate is not a
    /// byte-identical replay of it.
    case terminalForkDiverged
}

/// Why a persisted blob was refused at load time. Surfaced so the caller can
/// distinguish "never paired" (`nil`) from "there was something there and we
/// rejected it" — the latter feeds the tamper/repair classification and should
/// be logged loudly, in the same spirit as `SoyehtIdentityState.decodingFailed`.
public enum RosterProjectionLoadRejection: Equatable, Sendable {
    case blobUnreadable
    case versionUnsupported
    case householdMismatch
    /// Exactly one of (signer cert, snapshot body) was present. A half-written
    /// record is never served.
    case halfState
    /// Decode, canonicality, key-set, signature, digest or projection
    /// re-derivation failed against the household root.
    case authorityRejected
}

/// A fully re-derived roster state. Publicly readable, but not publicly
/// constructible: the only way to obtain one is to load or commit through the
/// store, which always rebuilds `projection` from `canonicalSnapshotBody` and
/// the household root key.
public struct RosterPersistedRoster: Sendable, Equatable {
    public let qrAnchorFingerprint: Data
    public let signerBinding: RosterSignerBinding
    public let projection: VerifiedRosterProjection
    public let canonicalSnapshotBody: Data

    init(
        qrAnchorFingerprint: Data,
        signerBinding: RosterSignerBinding,
        projection: VerifiedRosterProjection,
        canonicalSnapshotBody: Data
    ) {
        self.qrAnchorFingerprint = qrAnchorFingerprint
        self.signerBinding = signerBinding
        self.projection = projection
        self.canonicalSnapshotBody = canonicalSnapshotBody
    }
}

public enum RosterStoredState: Sendable, Equatable {
    /// Nothing usable. Either never seeded, or a persisted blob was rejected —
    /// check `lastRejection()` to tell those apart.
    case absent
    /// A QR anchor is pinned but no evidence has been accepted yet.
    case pendingAnchor(qrAnchorFingerprint: Data)
    /// Anchor + signer binding + re-derived projection.
    case current(RosterPersistedRoster)
}

/// Single-account, single-blob persistence for the verified roster projection
/// and the signer binding that produced it.
///
/// **Why one blob and not one account per field.** `RosterEvidenceVerifier`
/// couples the two: `.qrPin` demands `previousProjection == nil` while
/// `.stableBinding` demands it non-nil. If a binding could survive without its
/// projection (or the reverse) both anchors would throw `anchorMismatch` and
/// refresh would be permanently wedged with no code path out. `KeychainHelper`
/// implements `save` as delete-then-add, so a partial failure is real. Keeping
/// anchor + binding + snapshot bytes in one blob under one account means a
/// failed write can only lose the whole record — which degrades to "needs a
/// fresh QR", a state the pair flow can recover — never to a half-state.
///
/// **Why no projection is stored.** The projection, its `genesisCheckpointHash`,
/// its `eventHashes` and its `floorSecs` are all re-derived on every load from
/// `canonicalSnapshotBody` through `RosterEvidenceClient.decodeSnapshotBody`
/// and `RosterEvidenceVerifier.buildProjection`. Persisting them as scalars
/// would make them trusted input; re-deriving them makes the household root
/// key the only authority. Any failure along that path yields `.absent` rather
/// than a partially-populated object.
///
/// **What this store deliberately does not check.** It does not require the
/// persisted signer to still be an active member of the re-derived projection.
/// That is refresh-time policy (`requireSignerActiveMember`), not storage
/// integrity. Enforcing it here would silently drop the projection of a device
/// whose pinned Mac was revoked, which is exactly the case the caller needs to
/// see in order to surface an explicit re-pairing state.
public actor RosterProjectionStore {
    public static let defaultAccount = "household.roster.v1"

    private struct PersistedBlob: Codable, Equatable {
        var v: Int
        var hhId: String
        var qrAnchorFingerprint: Data
        /// Present together with `canonicalSnapshotBody`, or both absent
        /// (pending). `mId` and the cert fingerprint are re-derived from this
        /// rather than stored, so they cannot drift from the cert.
        var signerMachineCert: Data?
        var canonicalSnapshotBody: Data?
    }

    private static let blobVersion = 1

    public static func defaultStorage(
        for profile: SoyehtInstallProfile = .current
    ) -> KeychainHelper {
        KeychainHelper(
            service: profile.householdKeychainService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    private let storage: any HouseholdSecureStoring
    private let account: String
    private let expectedHouseholdId: String
    private let householdPublicKey: Data
    private var state: RosterStoredState
    private var rejection: RosterProjectionLoadRejection?

    /// Eagerly resolves persisted state, mirroring `CRLStore`. Unlike
    /// `CRLStore` this initialiser does not throw on a corrupt record: a
    /// rejected blob resolves to `.absent` with `lastRejection()` set, because
    /// the contract here is fail-closed-to-absent rather than fail-loud.
    public init(
        expectedHouseholdId: String,
        householdPublicKey: Data,
        storage: any HouseholdSecureStoring = RosterProjectionStore.defaultStorage(),
        account: String = RosterProjectionStore.defaultAccount
    ) {
        self.storage = storage
        self.account = account
        self.expectedHouseholdId = expectedHouseholdId
        self.householdPublicKey = householdPublicKey
        self.state = .absent
        self.rejection = nil
        let resolved = Self.resolve(
            storage: storage,
            account: account,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        self.state = resolved.state
        self.rejection = resolved.rejection
    }

    public func load() -> RosterStoredState { state }

    public func lastRejection() -> RosterProjectionLoadRejection? { rejection }

    /// Re-reads the secure store and re-derives from scratch. A record that has
    /// become unreadable resolves to `.absent`; the previously loaded value is
    /// NOT served as a fallback cache.
    @discardableResult
    public func reload() -> RosterStoredState {
        let resolved = Self.resolve(
            storage: storage,
            account: account,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        state = resolved.state
        rejection = resolved.rejection
        return state
    }

    /// Pins a QR machine-cert fingerprint. This is the only entry point that
    /// may introduce a new anchor, and it is the atomic anchor+binding+
    /// projection replacement the pair flow performs: a fingerprint that
    /// differs from the stored one drops any existing current.
    ///
    /// Idempotent when a current already exists under the same anchor — a
    /// re-pair against the same Mac must not discard a usable projection.
    public func seedPendingAnchor(qrAnchorFingerprint: Data) throws {
        guard qrAnchorFingerprint.count == 32 else {
            throw RosterProjectionStoreError.evidenceUnusable
        }
        if case .current(let existing) = state,
           existing.qrAnchorFingerprint == qrAnchorFingerprint {
            return
        }
        if case .pendingAnchor(let existing) = state, existing == qrAnchorFingerprint {
            return
        }
        let blob = PersistedBlob(
            v: Self.blobVersion,
            hhId: expectedHouseholdId,
            qrAnchorFingerprint: qrAnchorFingerprint,
            signerMachineCert: nil,
            canonicalSnapshotBody: nil
        )
        try persist(blob)
        state = .pendingAnchor(qrAnchorFingerprint: qrAnchorFingerprint)
        rejection = nil
    }

    /// Accepts verified-available evidence. There is deliberately no parameter
    /// by which an unavailable outcome could be expressed, and no API that
    /// clears a current — so an unavailable refresh cannot reach persistence at
    /// all, let alone erase the last good state.
    ///
    /// The projection is re-derived here from `canonicalSnapshotBody`; a
    /// caller-supplied projection is never accepted or trusted.
    @discardableResult
    public func commitCurrent(
        signerBinding: RosterSignerBinding,
        canonicalSnapshotBody: Data
    ) throws -> VerifiedRosterProjection {
        let anchor: Data
        switch state {
        case .absent:
            throw RosterProjectionStoreError.anchorMissing
        case .pendingAnchor(let fingerprint):
            anchor = fingerprint
        case .current(let existing):
            anchor = existing.qrAnchorFingerprint
        }

        guard signerBinding.hhId == expectedHouseholdId else {
            throw RosterProjectionStoreError.evidenceUnusable
        }
        let rederived = try Self.rederive(
            signerMachineCert: signerBinding.machineCert,
            canonicalSnapshotBody: canonicalSnapshotBody,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        guard rederived.binding.mId == signerBinding.mId,
              rederived.binding.machineCertFingerprint == signerBinding.machineCertFingerprint else {
            throw RosterProjectionStoreError.evidenceUnusable
        }

        if case .current(let existing) = state {
            guard rederived.projection.floorSecs >= existing.projection.floorSecs else {
                throw RosterProjectionStoreError.floorRollback
            }
            if existing.projection.isTerminalFork {
                guard rederived.projection.stateKind == existing.projection.stateKind,
                      rederived.projection.checkpointBytes == existing.projection.checkpointBytes,
                      rederived.projection.conflictingCheckpointBytes
                          == existing.projection.conflictingCheckpointBytes else {
                    throw RosterProjectionStoreError.terminalForkDiverged
                }
            }
        }

        let blob = PersistedBlob(
            v: Self.blobVersion,
            hhId: expectedHouseholdId,
            qrAnchorFingerprint: anchor,
            signerMachineCert: signerBinding.machineCert,
            canonicalSnapshotBody: canonicalSnapshotBody
        )
        try persist(blob)
        state = .current(RosterPersistedRoster(
            qrAnchorFingerprint: anchor,
            signerBinding: rederived.binding,
            projection: rederived.projection,
            canonicalSnapshotBody: canonicalSnapshotBody
        ))
        rejection = nil
        return rederived.projection
    }

    /// Persist first; publish in memory only after the store accepted the
    /// write. A refused write therefore never publishes the new state: the
    /// live instance keeps serving the previous one.
    ///
    /// It does NOT promise the previous record survives on disk. `KeychainHelper`
    /// implements `save` as delete-then-add, so a refusal may already have
    /// destroyed the blob. That is the acceptable failure: the next instance
    /// reads nothing and degrades to `.absent`, which the pair flow recovers
    /// from with a fresh QR. What is ruled out is a half-written record or a
    /// new state published on top of a failed write.
    private func persist(_ blob: PersistedBlob) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(blob)
        } catch {
            throw RosterProjectionStoreError.persistenceFailed
        }
        guard storage.save(data, account: account) else {
            throw RosterProjectionStoreError.persistenceFailed
        }
    }

    private static func resolve(
        storage: any HouseholdSecureStoring,
        account: String,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) -> (state: RosterStoredState, rejection: RosterProjectionLoadRejection?) {
        guard let data = storage.load(account: account) else {
            return (.absent, nil)
        }
        guard let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data) else {
            return (.absent, .blobUnreadable)
        }
        guard blob.v == blobVersion else {
            return (.absent, .versionUnsupported)
        }
        guard blob.hhId == expectedHouseholdId else {
            return (.absent, .householdMismatch)
        }
        guard blob.qrAnchorFingerprint.count == 32 else {
            return (.absent, .blobUnreadable)
        }
        switch (blob.signerMachineCert, blob.canonicalSnapshotBody) {
        case (nil, nil):
            return (.pendingAnchor(qrAnchorFingerprint: blob.qrAnchorFingerprint), nil)
        case (let cert?, let body?):
            guard let rederived = try? rederive(
                signerMachineCert: cert,
                canonicalSnapshotBody: body,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey
            ) else {
                return (.absent, .authorityRejected)
            }
            return (.current(RosterPersistedRoster(
                qrAnchorFingerprint: blob.qrAnchorFingerprint,
                signerBinding: rederived.binding,
                projection: rederived.projection,
                canonicalSnapshotBody: body
            )), nil)
        default:
            return (.absent, .halfState)
        }
    }

    /// The single re-derivation path, shared by load and commit so the two can
    /// never disagree about what a stored record means.
    private static func rederive(
        signerMachineCert: Data,
        canonicalSnapshotBody: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> (binding: RosterSignerBinding, projection: VerifiedRosterProjection) {
        let certBinding = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
            certCBOR: signerMachineCert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let snapshot = try RosterEvidenceClient.decodeSnapshotBody(
            canonicalSnapshotBody: canonicalSnapshotBody
        )
        let projection = try RosterEvidenceVerifier.buildProjection(
            snapshot: snapshot,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let binding = try RosterSignerBinding(
            hhId: expectedHouseholdId,
            mId: certBinding.mId,
            machineCert: signerMachineCert,
            machineCertFingerprint: certBinding.fingerprint
        )
        return (binding, projection)
    }
}
