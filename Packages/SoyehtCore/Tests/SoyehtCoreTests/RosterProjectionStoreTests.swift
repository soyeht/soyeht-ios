import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Persistence-contract tests for `RosterProjectionStore`.
///
/// Every assertion about persisted state is made through a **new store
/// instance** over the same fake secure storage. A same-instance assertion
/// would only prove the in-memory field was set, not that the record survives
/// a restart and re-derives correctly from the household root key.
struct RosterProjectionStoreTests {
    // MARK: - Fake secure storage (with injectable write failure)

    private final class FakeSecureStorage: HouseholdSecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var failSave = false

        func save(_ data: Data, account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            // Models `KeychainHelper.save`, which is delete-then-add: by the
            // time a write fails, the prior record is already gone. Modelling
            // this as an atomic refusal would let these tests assert a
            // durability guarantee production cannot deliver.
            guard !failSave else {
                values.removeValue(forKey: account)
                return false
            }
            values[account] = data
            return true
        }

        func load(account: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return values[account]
        }

        func delete(account: String) {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: account)
        }

        func setFailSave(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            failSave = value
        }

        var accounts: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return Set(values.keys)
        }

        func rawBlob(account: String) -> Data? { load(account: account) }

        func overwrite(_ data: Data, account: String) {
            lock.lock(); defer { lock.unlock() }
            values[account] = data
        }
    }

    private let account = RosterProjectionStore.defaultAccount
    private let anchorFingerprint = Data(repeating: 0xAB, count: 32)

    // MARK: - Deterministic synthetic keys (no real material)

    private func rootKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
    }

    private func otherRootKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((129...160).map(UInt8.init)))
    }

    private func ownerKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((33...64).map(UInt8.init)))
    }

    private func machine1Key() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
    }

    private func machine2Key() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((97...128).map(UInt8.init)))
    }

    // MARK: - CBOR corpus helpers

    private func certSigner(
        _ map: [String: HouseholdCBORValue],
        with key: P256.Signing.PrivateKey
    ) throws -> Data {
        var unsigned = [String: HouseholdCBORValue]()
        for (k, v) in map where k != "signature" { unsigned[k] = v }
        let sig = try key.signature(for: HouseholdCBOR.encode(.map(unsigned)))
        var signed = map
        signed["signature"] = .bytes(sig.rawRepresentation)
        return HouseholdCBOR.encode(.map(signed))
    }

    private func validOwnerCaveats() -> [HouseholdCBORValue] {[
        .map(["op": .text("claws.list"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
        .map(["op": .text("claws.create"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
        .map(["op": .text("claws.delete"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
        .map(["op": .text("claws.use"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
        .map(["op": .text("claws.assign"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
        .map(["op": .text("household.invite"), "scope": .null, "constraints": .null]),
        .map(["op": .text("household.revoke"), "scope": .null, "constraints": .null]),
        .map(["op": .text("household.add_machine"), "scope": .null, "constraints": .null]),
    ]}

    private func machineCert(
        root: P256.Signing.PrivateKey, hhId: String,
        machinePriv: P256.Signing.PrivateKey, hostname: String, issuedAt: UInt64
    ) throws -> (cert: Data, mId: String, mPub: Data, fingerprint: Data) {
        let mPub = machinePriv.publicKey.compressedRepresentation
        let mId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
        let cert = try certSigner([
            "v": .unsigned(1), "type": .text("machine"),
            "hh_id": .text(hhId), "m_id": .text(mId), "m_pub": .bytes(mPub),
            "hostname": .text(hostname), "platform": .text("macos"),
            "joined_at": .unsigned(issuedAt), "issued_by": .text(hhId),
            "caveats": .array([]),
        ], with: root)
        return (cert, mId, mPub, Data(SHA256.hash(data: cert)))
    }

    private func makeOwnerCert(
        root: P256.Signing.PrivateKey, owner: P256.Signing.PrivateKey,
        hhId: String, issuedAt: UInt64
    ) throws -> (cert: Data, pId: String, fingerprint: Data) {
        let oPub = owner.publicKey.compressedRepresentation
        let pId = try HouseholdIdentifiers.personIdentifier(for: oPub)
        let cert = try certSigner([
            "v": .unsigned(1), "type": .text("person"),
            "hh_id": .text(hhId), "p_id": .text(pId), "p_pub": .bytes(oPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt), "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt), "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        return (cert, pId, Data(SHA256.hash(data: cert)))
    }

    private func memberMap(
        mId: String, mPub: Data, machineCert: Data, fingerprint: Data
    ) -> [String: HouseholdCBORValue] {
        [
            "m_id": .text(mId), "m_pub": .bytes(mPub),
            "machine_cert": .bytes(machineCert),
            "machine_cert_fingerprint": .bytes(fingerprint),
        ]
    }

    private func makeCheckpoint(
        owner: P256.Signing.PrivateKey, hhId: String, epoch: Data,
        seq: UInt64, prevHash: Data, eventSeq: UInt64, eventHead: Data,
        meshDigest: Data, issuedAt: UInt64, notAfter: UInt64,
        pId: String, pCertFingerprint: Data,
        active: [[String: HouseholdCBORValue]],
        revocations: [[String: HouseholdCBORValue]],
        pCert: Data
    ) throws -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "kind": .text(RosterAuthorityVerifier.checkpointKind),
            "hh_id": .text(hhId), "epoch": .bytes(epoch),
            "checkpoint_sequence": .unsigned(seq),
            "prev_checkpoint_hash": .bytes(prevHash),
            "event_sequence": .unsigned(eventSeq),
            "event_head_hash": .bytes(eventHead),
            "mesh_log_digest": .bytes(meshDigest),
            "issued_at": .unsigned(issuedAt),
            "not_after": .unsigned(notAfter),
            "owner_p_id": .text(pId),
            "owner_cert_fingerprint": .bytes(pCertFingerprint),
            "active": .array(active.map { .map($0) }),
            "revocations": .array(revocations.map { .map($0) }),
            "owner_person_cert": .bytes(pCert),
        ]
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.checkpointUnsignedKeys { unsigned[key] = map[key] }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        let sig = try owner.signature(for: RosterAuthorityVerifier.checkpointDomain + canonicalUnsigned)
        map["signature"] = .bytes(sig.rawRepresentation)
        return HouseholdCBOR.encode(.map(map))
    }

    private func makeRevocation(
        owner: P256.Signing.PrivateKey,
        mId: String, mPub: Data, mCertFingerprint: Data,
        hhId: String, epoch: Data, sequence: UInt64,
        prevEventHash: Data, revokedAt: UInt64,
        pId: String, pCertFingerprint: Data, pCert: Data
    ) throws -> (map: [String: HouseholdCBORValue], eventHash: Data) {
        var revMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(epoch),
            "sequence": .unsigned(sequence),
            "prev_event_hash": .bytes(prevEventHash),
            "m_id": .text(mId), "m_pub": .bytes(mPub),
            "machine_cert_fingerprint": .bytes(mCertFingerprint),
            "revoked_at": .unsigned(revokedAt),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(pId),
            "owner_cert_fingerprint": .bytes(pCertFingerprint),
            "owner_person_cert": .bytes(pCert),
        ]
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { unsigned[key] = revMap[key] }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        let eventHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: canonicalUnsigned)
        let sig = try owner.signature(for: RosterAuthorityVerifier.revocationDomain + canonicalUnsigned)
        revMap["signature"] = .bytes(sig.rawRepresentation)
        return (revMap, eventHash)
    }

    private func snapshotBodyMap(
        _ snapshot: RosterEvidenceSnapshotBody
    ) -> [String: HouseholdCBORValue] {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(snapshot.v), "hh_id": .text(snapshot.hhId),
            "state_kind": .unsigned(snapshot.stateKind),
            "floor_secs": .unsigned(snapshot.floorSecs),
        ]
        if let g = snapshot.genesisCheckpoint { map["genesis_checkpoint"] = .bytes(g) }
        if let a = snapshot.acceptedCheckpoint { map["accepted_checkpoint"] = .bytes(a) }
        if let p = snapshot.predecessorCheckpoint { map["predecessor_checkpoint"] = .bytes(p) }
        if let c = snapshot.conflictingCheckpoint { map["conflicting_checkpoint"] = .bytes(c) }
        return map
    }

    private func canonicalBody(_ snapshot: RosterEvidenceSnapshotBody) -> Data {
        HouseholdCBOR.encode(.map(snapshotBodyMap(snapshot)))
    }

    // MARK: - Assembled corpora

    private struct Corpus {
        let hhId: String
        let rootPub: Data
        let binding: RosterSignerBinding
        let body: Data
        let genesisCheckpointHash: Data
        let eventHashes: [Data]
        let floorSecs: UInt64
    }

    /// Accepted state at `checkpoint_sequence == 2` with one revocation, so the
    /// re-derived projection has a non-nil genesis pin AND a non-empty event
    /// hash list — the two a3 fields that must never be stored as scalars.
    private func acceptedSeq2Corpus(hhId: String) throws -> Corpus {
        let root = try rootKey(); let owner = try ownerKey()
        let rootPub = root.publicKey.compressedRepresentation
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-alpha", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-beta", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId,
            householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(
            owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp,
            hhId: hhId, epoch: epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt,
            pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let refreshRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 2,
            prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash,
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp,
            active: [m1Entry], revocations: [revMap], pCert: oCert)
        let snap = RosterEvidenceSnapshotBody(
            v: 1, hhId: hhId, stateKind: 1,
            genesisCheckpoint: genesisRaw, acceptedCheckpoint: refreshRaw,
            predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil,
            floorSecs: issuedAt + 10)
        return Corpus(
            hhId: hhId, rootPub: rootPub,
            binding: try RosterSignerBinding(
                hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp),
            body: canonicalBody(snap),
            genesisCheckpointHash: genesis.checkpointHash,
            eventHashes: [revHash],
            floorSecs: issuedAt + 10)
    }

    /// Genesis-only accepted state at a strictly lower `floor_secs` than
    /// `acceptedSeq2Corpus`, for the rollback test.
    private func acceptedGenesisCorpus(hhId: String) throws -> Corpus {
        let root = try rootKey(); let owner = try ownerKey()
        let rootPub = root.publicKey.compressedRepresentation
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-alpha", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let genesisRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: [m1Entry], revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId,
            householdPublicKey: rootPub, effectiveNow: issuedAt)
        let snap = RosterEvidenceSnapshotBody(
            v: 1, hhId: hhId, stateKind: 1,
            genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw,
            predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        return Corpus(
            hhId: hhId, rootPub: rootPub,
            binding: try RosterSignerBinding(
                hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp),
            body: canonicalBody(snap),
            genesisCheckpointHash: genesis.checkpointHash,
            eventHashes: [], floorSecs: issuedAt)
    }

    /// Checkpoint-fork state. `meshDigestVariant` changes only the conflicting
    /// checkpoint, producing a same-kind fork that is NOT a byte-identical
    /// replay.
    private func checkpointForkCorpus(hhId: String, conflictingMesh: UInt8) throws -> Corpus {
        let root = try rootKey(); let owner = try ownerKey()
        let rootPub = root.publicKey.compressedRepresentation
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-alpha", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let genesisRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: [m1Entry], revocations: [], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: conflictingMesh, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: [m1Entry], revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId,
            householdPublicKey: rootPub, effectiveNow: issuedAt)
        let snap = RosterEvidenceSnapshotBody(
            v: 1, hhId: hhId, stateKind: 2,
            genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw,
            predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw,
            floorSecs: issuedAt)
        return Corpus(
            hhId: hhId, rootPub: rootPub,
            binding: try RosterSignerBinding(
                hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp),
            body: canonicalBody(snap),
            genesisCheckpointHash: genesis.checkpointHash,
            eventHashes: [], floorSecs: issuedAt)
    }

    private func makeStore(
        _ corpus: Corpus, storage: FakeSecureStorage
    ) -> RosterProjectionStore {
        RosterProjectionStore(
            expectedHouseholdId: corpus.hhId,
            householdPublicKey: corpus.rootPub,
            storage: storage,
            account: account
        )
    }

    // MARK: - Pending anchor

    @Test func pendingAnchorSurvivesReloadInNewInstance() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_pend")
        let storage = FakeSecureStorage()
        let first = makeStore(corpus, storage: storage)
        try await first.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)

        let reloaded = makeStore(corpus, storage: storage)
        #expect(await reloaded.load() == .pendingAnchor(qrAnchorFingerprint: anchorFingerprint))
        #expect(await reloaded.lastRejection() == nil)
    }

    /// A pending anchor must never be mistaken for a usable current, and a
    /// current cannot be created without an anchor first.
    @Test func pendingIsNeverCurrentAndCommitRequiresAnchor() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_pnc")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)

        await #expect(throws: RosterProjectionStoreError.anchorMissing) {
            try await store.commitCurrent(
                signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)
        }

        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        let reloaded = makeStore(corpus, storage: storage)
        guard case .pendingAnchor = await reloaded.load() else {
            Issue.record("expected pendingAnchor, not current")
            return
        }
    }

    // MARK: - Current round-trip with re-derivation

    @Test func currentRederivesGenesisPinAndEventHashesInNewInstance() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_cur")
        let storage = FakeSecureStorage()
        let first = makeStore(corpus, storage: storage)
        try await first.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await first.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        let reloaded = makeStore(corpus, storage: storage)
        guard case .current(let loaded) = await reloaded.load() else {
            Issue.record("expected current after reload")
            return
        }
        #expect(loaded.qrAnchorFingerprint == anchorFingerprint)
        #expect(loaded.canonicalSnapshotBody == corpus.body)
        #expect(loaded.signerBinding == corpus.binding)
        // The a3 continuity fields and the floor are re-derived from the
        // canonical bytes, never read back as stored scalars.
        #expect(loaded.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(loaded.projection.checkpointSequence == 2)
        #expect(loaded.projection.genesisCheckpointHash == corpus.genesisCheckpointHash)
        #expect(loaded.projection.eventHashes == corpus.eventHashes)
        #expect(loaded.projection.eventHeadHash == corpus.eventHashes[0])
        #expect(loaded.projection.floorSecs == corpus.floorSecs)
        #expect(loaded.projection.tombstones.count == 1)
        #expect(loaded.projection.activeMembers.count == 1)
        #expect(loaded.projection.activeMembers[0].mId == corpus.binding.mId)
    }

    @Test func singleAccountHoldsTheEntireRecord() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_one")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        #expect(storage.accounts == [account])
    }

    // MARK: - Fail-closed load

    @Test func corruptedBlobLoadsAbsentAndDoesNotServeStaleCache() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_corr")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        storage.overwrite(Data("not json".utf8), account: account)

        // Same instance: the previously good value must NOT be served.
        #expect(await store.reload() == .absent)
        #expect(await store.lastRejection() == .blobUnreadable)

        let reloaded = makeStore(corpus, storage: storage)
        #expect(await reloaded.load() == .absent)
        #expect(await reloaded.lastRejection() == .blobUnreadable)
    }

    @Test func nonCanonicalSnapshotBodyLoadsAbsent() async throws {
        let corpus = try acceptedGenesisCorpus(hhId: "hh_noncanon")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        // Re-emit the same snapshot map with its keys in reverse canonical
        // order: valid CBOR that decodes, but re-encodes to different bytes.
        guard case .map(let decoded) = try HouseholdCBOR.decode(corpus.body) else {
            Issue.record("corpus body is not a map"); return
        }
        let reversed = decoded
            .map { (key: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                HouseholdCBOR.encode(.text(rhs.key))
                    .lexicographicallyPrecedes(HouseholdCBOR.encode(.text(lhs.key)))
            }
        var noncanonical = Data([0xA0 | UInt8(reversed.count)])
        for (key, value) in reversed {
            noncanonical.append(HouseholdCBOR.encode(.text(key)))
            noncanonical.append(HouseholdCBOR.encode(value))
        }
        #expect(noncanonical != corpus.body)

        let tampered = try #require(
            Self.rewriteBlobBody(storage.rawBlob(account: account), body: noncanonical))
        storage.overwrite(tampered, account: account)

        let reloaded = makeStore(corpus, storage: storage)
        #expect(await reloaded.load() == .absent)
        #expect(await reloaded.lastRejection() == .authorityRejected)
    }

    @Test func wrongHouseholdLoadsAbsent() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_wronghh")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        let foreign = RosterProjectionStore(
            expectedHouseholdId: "hh_someoneelse",
            householdPublicKey: corpus.rootPub,
            storage: storage,
            account: account
        )
        #expect(await foreign.load() == .absent)
        #expect(await foreign.lastRejection() == .householdMismatch)
    }

    @Test func wrongRootKeyLoadsAbsent() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_wrongroot")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        let wrongRoot = RosterProjectionStore(
            expectedHouseholdId: corpus.hhId,
            householdPublicKey: try otherRootKey().publicKey.compressedRepresentation,
            storage: storage,
            account: account
        )
        #expect(await wrongRoot.load() == .absent)
        #expect(await wrongRoot.lastRejection() == .authorityRejected)
    }

    @Test func halfStateBlobLoadsAbsent() async throws {
        let corpus = try acceptedSeq2Corpus(hhId: "hh_half")
        let storage = FakeSecureStorage()
        let store = makeStore(corpus, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: corpus.binding, canonicalSnapshotBody: corpus.body)

        // Drop only the snapshot body, keeping the signer cert: the shape a
        // split-account design could produce. It must never be served.
        let half = try #require(
            Self.rewriteBlobBody(storage.rawBlob(account: account), body: nil))
        storage.overwrite(half, account: account)

        let reloaded = makeStore(corpus, storage: storage)
        #expect(await reloaded.load() == .absent)
        #expect(await reloaded.lastRejection() == .halfState)
    }

    // MARK: - Persist-before-publish

    @Test func refusedWriteKeepsPreviousCurrentInMemoryAndDegradesToAbsent() async throws {
        let hhId = "hh_failsave"
        let low = try acceptedGenesisCorpus(hhId: hhId)
        let high = try acceptedSeq2Corpus(hhId: hhId)
        let storage = FakeSecureStorage()
        let store = makeStore(low, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: low.binding, canonicalSnapshotBody: low.body)

        storage.setFailSave(true)
        await #expect(throws: RosterProjectionStoreError.persistenceFailed) {
            try await store.commitCurrent(
                signerBinding: high.binding, canonicalSnapshotBody: high.body)
        }

        // The new state was never published: the live instance still serves the
        // previous current.
        guard case .current(let live) = await store.load() else {
            Issue.record("expected the previous current to survive in memory"); return
        }
        #expect(live.canonicalSnapshotBody == low.body)

        // Delete-then-add already destroyed the record, so there is nothing on
        // disk to reload. That is the accepted loss.
        #expect(storage.rawBlob(account: account) == nil)

        // A restart therefore sees total loss, which is indistinguishable from
        // never having paired: `.absent` with no rejection marker. Neither a
        // stale current nor a half-written record is ever served.
        let reloaded = makeStore(low, storage: storage)
        #expect(await reloaded.load() == .absent)
        #expect(await reloaded.lastRejection() == nil)
    }

    // MARK: - Floor monotonicity

    @Test func floorRollbackRejectedAndHighFloorSurvivesRestart() async throws {
        let hhId = "hh_floor"
        let high = try acceptedSeq2Corpus(hhId: hhId)
        let low = try acceptedGenesisCorpus(hhId: hhId)
        #expect(low.floorSecs < high.floorSecs)

        let storage = FakeSecureStorage()
        let store = makeStore(high, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        try await store.commitCurrent(
            signerBinding: high.binding, canonicalSnapshotBody: high.body)

        await #expect(throws: RosterProjectionStoreError.floorRollback) {
            try await store.commitCurrent(
                signerBinding: low.binding, canonicalSnapshotBody: low.body)
        }

        let reloaded = makeStore(high, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected current after restart"); return
        }
        #expect(persisted.projection.floorSecs == high.floorSecs)
        #expect(persisted.canonicalSnapshotBody == high.body)
    }

    // MARK: - Terminal fork absorbing

    @Test func terminalForkAcceptsExactReplayAndRejectsDivergence() async throws {
        let hhId = "hh_fork"
        let fork = try checkpointForkCorpus(hhId: hhId, conflictingMesh: 0xDD)
        let diverged = try checkpointForkCorpus(hhId: hhId, conflictingMesh: 0xEE)
        #expect(fork.body != diverged.body)

        let storage = FakeSecureStorage()
        let store = makeStore(fork, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: anchorFingerprint)
        let committed = try await store.commitCurrent(
            signerBinding: fork.binding, canonicalSnapshotBody: fork.body)
        #expect(committed.isTerminalFork)

        // Byte-identical replay is accepted.
        try await store.commitCurrent(
            signerBinding: fork.binding, canonicalSnapshotBody: fork.body)

        // A same-kind fork with a different conflicting checkpoint is not.
        await #expect(throws: RosterProjectionStoreError.terminalForkDiverged) {
            try await store.commitCurrent(
                signerBinding: diverged.binding, canonicalSnapshotBody: diverged.body)
        }

        let reloaded = makeStore(fork, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected fork current after restart"); return
        }
        #expect(persisted.projection.isTerminalFork)
        #expect(persisted.canonicalSnapshotBody == fork.body)
        #expect(persisted.projection.stateKind == VerifiedRosterProjection.stateKindCheckpointFork)
    }

    // MARK: - Blob surgery helper

    /// Rewrites the persisted blob's `canonicalSnapshotBody` (or removes it),
    /// leaving every other field untouched. Operates on the JSON the store
    /// writes, so the tests do not need access to its private `Codable` type.
    private static func rewriteBlobBody(_ blob: Data?, body: Data?) -> Data? {
        guard let blob,
              var object = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any] else {
            return nil
        }
        if let body {
            object["canonicalSnapshotBody"] = body.base64EncodedString()
        } else {
            object.removeValue(forKey: "canonicalSnapshotBody")
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
