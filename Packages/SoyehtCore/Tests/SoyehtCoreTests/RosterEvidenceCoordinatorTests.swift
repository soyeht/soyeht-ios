import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Behavioural tests for `RosterEvidenceCoordinator`.
///
/// Everything is injected: evidence fetch, currency probe, nonce, clock and
/// secure storage. The probe records its call count so "no probe for any error
/// other than anchorMismatch" is asserted rather than assumed. Where a test
/// concerns persistence, the store is re-read through a fresh instance.
struct RosterEvidenceCoordinatorTests {
    // MARK: - Fakes

    private final class FakeSecureStorage: HouseholdSecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var failSave = false

        func save(_ data: Data, account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            // Same delete-then-add fidelity as the store suite's fake.
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

        func overwrite(_ data: Data, account: String) {
            lock.lock(); defer { lock.unlock() }
            values[account] = data
        }
    }

    /// Counts probe invocations so the "exactly one, and only for
    /// anchorMismatch" rule is directly observable.
    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private let account = RosterProjectionStore.defaultAccount
    private let anchorFingerprint = Data(repeating: 0xAB, count: 32)
    private let testNonce = Data(repeating: 0x5A, count: 32)
    private let fixedNow = Date(timeIntervalSince1970: 1_100)

    private func neverProbe(_ recorder: ProbeRecorder) -> RosterEvidenceCoordinator.CurrencyProbe {
        { _ in
            recorder.record()
            throw RosterCurrencyClientError.transportFailed
        }
    }

    // MARK: - Deterministic synthetic keys

    private func rootKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
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

    // MARK: - CBOR corpus

    private func certSigner(
        _ map: [String: HouseholdCBORValue], with key: P256.Signing.PrivateKey
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

    /// Returns the canonical, owner-signed revocation exactly as the currency
    /// endpoint would return it, so the coordinator's proof path sees real bytes.
    private func makeRevocation(
        owner: P256.Signing.PrivateKey,
        mId: String, mPub: Data, mCertFingerprint: Data,
        hhId: String, epoch: Data, sequence: UInt64,
        prevEventHash: Data, revokedAt: UInt64,
        pId: String, pCertFingerprint: Data, pCert: Data
    ) throws -> (canonical: Data, tombstone: RosterCurrencyTombstone) {
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
        let sig = try owner.signature(for: RosterAuthorityVerifier.revocationDomain + canonicalUnsigned)
        revMap["signature"] = .bytes(sig.rawRepresentation)
        let canonical = HouseholdCBOR.encode(.map(revMap))
        let tombstone = RosterCurrencyTombstone(
            v: 1, kind: RosterAuthorityVerifier.revocationKind,
            hhId: hhId, epoch: epoch, sequence: sequence,
            prevEventHash: prevEventHash, mId: mId, mPub: mPub,
            machineCertFingerprint: mCertFingerprint, revokedAt: revokedAt,
            reason: 1, cascade: 0, ownerPId: pId,
            ownerCertFingerprint: pCertFingerprint, ownerPersonCert: pCert,
            signature: sig.rawRepresentation, canonicalTombstone: canonical
        )
        return (canonical, tombstone)
    }

    private func snapshotBodyMap(
        _ snapshot: RosterEvidenceSnapshotBody, includeFloor: Bool
    ) -> [String: HouseholdCBORValue] {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(snapshot.v), "hh_id": .text(snapshot.hhId),
            "state_kind": .unsigned(snapshot.stateKind),
        ]
        if includeFloor { map["floor_secs"] = .unsigned(snapshot.floorSecs) }
        if let g = snapshot.genesisCheckpoint { map["genesis_checkpoint"] = .bytes(g) }
        if let a = snapshot.acceptedCheckpoint { map["accepted_checkpoint"] = .bytes(a) }
        if let p = snapshot.predecessorCheckpoint { map["predecessor_checkpoint"] = .bytes(p) }
        if let c = snapshot.conflictingCheckpoint { map["conflicting_checkpoint"] = .bytes(c) }
        return map
    }

    private func canonicalBody(_ snapshot: RosterEvidenceSnapshotBody) -> Data {
        HouseholdCBOR.encode(.map(snapshotBodyMap(snapshot, includeFloor: true)))
    }

    private func evidenceResponse(
        machinePriv: P256.Signing.PrivateKey, mId: String,
        machineCert: Data, machineCertFingerprint: Data,
        nonce: Data, outcome: String,
        snapshotBody: RosterEvidenceSnapshotBody?,
        corruptSignature: Bool = false
    ) throws -> RosterEvidenceResponse {
        var unsigned: [String: HouseholdCBORValue] = [
            "client_nonce": .bytes(nonce), "outcome": .text(outcome),
            "signer_m_id": .text(mId),
            "signer_machine_cert": .bytes(machineCert),
            "signer_machine_cert_fingerprint": .bytes(machineCertFingerprint),
            "v": .unsigned(1),
        ]
        var evDigest: Data?
        var snapDigest: Data?
        if let snap = snapshotBody {
            unsigned["snapshot_body"] = .map(snapshotBodyMap(snap, includeFloor: true))
            let evBody = HouseholdCBOR.encode(.map(snapshotBodyMap(snap, includeFloor: false)))
            evDigest = Data(SHA256.hash(data: RosterEvidenceVerifier.evidenceDomain + evBody))
            let snapBody = canonicalBody(snap)
            snapDigest = Data(SHA256.hash(data: RosterEvidenceVerifier.snapshotDomain + snapBody))
            unsigned["state_evidence_digest"] = .bytes(evDigest!)
            unsigned["full_snapshot_digest"] = .bytes(snapDigest!)
        }
        let preimage = RosterEvidenceVerifier.evidenceDomain + HouseholdCBOR.encode(.map(unsigned))
        var signature = try machinePriv.signature(for: preimage).rawRepresentation
        if corruptSignature {
            signature[0] ^= 0xFF
        }
        return RosterEvidenceResponse(
            v: 1, outcome: outcome, snapshotBody: snapshotBody,
            stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest,
            signerMId: mId, signerMachineCert: machineCert,
            signerMachineCertFingerprint: machineCertFingerprint,
            clientNonce: nonce, signature: signature
        )
    }

    // MARK: - Assembled scenario

    /// One household with a genesis checkpoint (signer = machine1, active) and
    /// a seq-2 advance that revokes machine2. Carries everything the
    /// coordinator's paths need.
    private struct Scenario {
        let hhId: String
        let rootPub: Data
        let epoch: Data
        let signerKey: P256.Signing.PrivateKey
        let signerMId: String
        let signerCert: Data
        let signerFingerprint: Data
        let genesisSnapshot: RosterEvidenceSnapshotBody
        let advanceSnapshot: RosterEvidenceSnapshotBody
        let forkSnapshot: RosterEvidenceSnapshotBody
        let ownerKey: P256.Signing.PrivateKey
        let ownerPId: String
        let ownerCert: Data
        let ownerFingerprint: Data
        let otherMId: String
        let otherPub: Data
        let otherFingerprint: Data
    }

    private func scenario(hhId: String) throws -> Scenario {
        let root = try rootKey(); let owner = try ownerKey()
        let rootPub = root.publicKey.compressedRepresentation
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1_000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-alpha", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(
            root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-beta", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let bothActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: bothActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId,
            householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (_, revTombstone) = try makeRevocation(
            owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp,
            hhId: hhId, epoch: epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt,
            pId: pId, pCertFingerprint: oFp, pCert: oCert)
        var revMapForCheckpoint: [String: HouseholdCBORValue] = [:]
        if case .map(let m) = try HouseholdCBOR.decode(revTombstone.canonicalTombstone) {
            revMapForCheckpoint = m
        }
        let advanceRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 2,
            prevHash: genesis.checkpointHash, eventSeq: 1,
            eventHead: RosterAuthorityVerifier.revocationEventHash(
                canonicalUnsigned: {
                    var unsigned: [String: HouseholdCBORValue] = [:]
                    for key in RosterAuthorityVerifier.revocationUnsignedKeys {
                        unsigned[key] = revMapForCheckpoint[key]
                    }
                    return HouseholdCBOR.encode(.map(unsigned))
                }()),
            meshDigest: Data(repeating: 0xCC, count: 32),
            issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp,
            active: [m1Entry], revocations: [revMapForCheckpoint], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(
            owner: owner, hhId: hhId, epoch: epoch, seq: 1,
            prevHash: RosterAuthorityVerifier.zeroHash32, eventSeq: 0,
            eventHead: RosterAuthorityVerifier.zeroHash32,
            meshDigest: Data(repeating: 0xDD, count: 32),
            issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp,
            active: bothActive, revocations: [], pCert: oCert)

        return Scenario(
            hhId: hhId, rootPub: rootPub, epoch: epoch,
            signerKey: m1Key, signerMId: m1Id, signerCert: m1Cert, signerFingerprint: m1Fp,
            genesisSnapshot: RosterEvidenceSnapshotBody(
                v: 1, hhId: hhId, stateKind: 1,
                genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw,
                predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt),
            advanceSnapshot: RosterEvidenceSnapshotBody(
                v: 1, hhId: hhId, stateKind: 1,
                genesisCheckpoint: genesisRaw, acceptedCheckpoint: advanceRaw,
                predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil,
                floorSecs: issuedAt + 10),
            forkSnapshot: RosterEvidenceSnapshotBody(
                v: 1, hhId: hhId, stateKind: 2,
                genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw,
                predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw,
                floorSecs: issuedAt),
            ownerKey: owner, ownerPId: pId, ownerCert: oCert, ownerFingerprint: oFp,
            otherMId: m2Id, otherPub: m2Pub, otherFingerprint: m2Fp)
    }

    private func makeStore(
        _ s: Scenario, storage: FakeSecureStorage
    ) -> RosterProjectionStore {
        RosterProjectionStore(
            expectedHouseholdId: s.hhId, householdPublicKey: s.rootPub,
            storage: storage, account: account)
    }

    private func makeCoordinator(
        _ s: Scenario,
        store: RosterProjectionStore,
        fetch: @escaping RosterEvidenceCoordinator.EvidenceFetch,
        probe: @escaping RosterEvidenceCoordinator.CurrencyProbe
    ) -> RosterEvidenceCoordinator {
        RosterEvidenceCoordinator(
            store: store, expectedHouseholdId: s.hhId, householdPublicKey: s.rootPub,
            fetchEvidence: fetch, probeCurrency: probe,
            nonceProvider: { self.testNonce }, now: { self.fixedNow })
    }

    /// Seeds the anchor and lands the genesis snapshot as `current`.
    private func seededCurrent(
        _ s: Scenario, storage: FakeSecureStorage
    ) async throws -> RosterProjectionStore {
        let store = makeStore(s, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: s.signerFingerprint)
        let binding = try RosterSignerBinding(
            hhId: s.hhId, mId: s.signerMId,
            machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint)
        try await store.commitCurrent(
            signerBinding: binding, canonicalSnapshotBody: canonicalBody(s.genesisSnapshot))
        return store
    }

    // MARK: - Bootstrap

    @Test func bootstrapAbsentWithoutRejectionIsUnknownNotTamper() async throws {
        let s = try scenario(hhId: "hh_bootabs")
        let storage = FakeSecureStorage()
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: makeStore(s, storage: storage),
            fetch: { _ in throw RosterEvidenceClientError.transportFailed },
            probe: neverProbe(recorder))

        #expect(await coordinator.bootstrap() == .unknown)
        #expect(recorder.callCount == 0)
    }

    @Test func bootstrapAbsentWithRejectionIsTamper() async throws {
        let s = try scenario(hhId: "hh_bootrej")
        let storage = FakeSecureStorage()
        _ = try await seededCurrent(s, storage: storage)
        storage.overwrite(Data("not json".utf8), account: account)

        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: makeStore(s, storage: storage),
            fetch: { _ in throw RosterEvidenceClientError.transportFailed },
            probe: neverProbe(recorder))

        #expect(
            await coordinator.bootstrap()
                == .tamperSuspected(.storedStateRejected(.blobUnreadable)))
        #expect(recorder.callCount == 0)
    }

    @Test func bootstrapPublishesStoredCurrentWithoutFetching() async throws {
        let s = try scenario(hhId: "hh_bootcur")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { _ in
                Issue.record("bootstrap must not fetch")
                throw RosterEvidenceClientError.transportFailed
            },
            probe: neverProbe(recorder))

        guard case .current(let projection) = await coordinator.bootstrap() else {
            Issue.record("expected current"); return
        }
        #expect(projection.checkpointSequence == 1)
        #expect(recorder.callCount == 0)
    }

    // MARK: - Happy paths

    @Test func pendingQrPinAdvancesToCurrentAndPersists() async throws {
        let s = try scenario(hhId: "hh_pin2cur")
        let storage = FakeSecureStorage()
        let store = makeStore(s, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: s.signerFingerprint)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.genesisSnapshot)
            },
            probe: neverProbe(recorder))

        guard case .current(let projection) = await coordinator.refresh() else {
            Issue.record("expected current"); return
        }
        #expect(projection.checkpointSequence == 1)
        #expect(recorder.callCount == 0)

        // Persisted: a brand new store instance re-derives the same current.
        let reloaded = makeStore(s, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected persisted current"); return
        }
        #expect(persisted.projection == projection)
    }

    @Test func currentStableBindingAdvancesToNewerCheckpoint() async throws {
        let s = try scenario(hhId: "hh_advance")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.advanceSnapshot)
            },
            probe: neverProbe(recorder))

        guard case .current(let projection) = await coordinator.refresh() else {
            Issue.record("expected current"); return
        }
        #expect(projection.checkpointSequence == 2)
        #expect(projection.tombstones == [s.otherMId])
        #expect(recorder.callCount == 0)

        let reloaded = makeStore(s, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected persisted advance"); return
        }
        #expect(persisted.projection.checkpointSequence == 2)
    }

    @Test func availableTerminalForkPublishesTerminalAndAbsorbsReplay() async throws {
        let s = try scenario(hhId: "hh_termfork")
        let storage = FakeSecureStorage()
        let store = makeStore(s, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: s.signerFingerprint)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.forkSnapshot)
            },
            probe: neverProbe(recorder))

        guard case .terminalFork(let forked) = await coordinator.refresh() else {
            Issue.record("expected terminalFork"); return
        }
        #expect(forked.isTerminalFork)

        // Byte-identical replay stays terminal rather than escaping.
        guard case .terminalFork = await coordinator.refresh() else {
            Issue.record("expected terminalFork on replay"); return
        }
        #expect(recorder.callCount == 0)

        let reloaded = makeStore(s, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected persisted fork"); return
        }
        #expect(persisted.projection.isTerminalFork)
    }

    // MARK: - Degraded: never writes, never clears, always carries lastKnown

    @Test func engineUnavailableDegradesWithLastKnownAndLeavesStoreCurrent() async throws {
        let s = try scenario(hhId: "hh_unavail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let before = await store.load()
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "unavailable_checkpoint_stale", snapshotBody: nil)
            },
            probe: neverProbe(recorder))

        guard case .degraded(let reason, let lastKnown) = await coordinator.refresh() else {
            Issue.record("expected degraded"); return
        }
        #expect(reason == .engine(outcome: "unavailable_checkpoint_stale"))
        guard case .current(let stored) = before else {
            Issue.record("fixture should start current"); return
        }
        #expect(lastKnown == stored.projection)
        #expect(recorder.callCount == 0)

        // No write and no clear: the store still holds the same record, and a
        // fresh instance still reads current.
        #expect(await store.load() == before)
        let reloaded = makeStore(s, storage: storage)
        guard case .current(let persisted) = await reloaded.load() else {
            Issue.record("expected store to stay current"); return
        }
        #expect(persisted.projection == stored.projection)
    }

    @Test func transportFailureDegradesWithLastKnownAndNextRefreshStillUsesIt() async throws {
        let s = try scenario(hhId: "hh_transport")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let failing = ProbeRecorder()
        let coordinator = RosterEvidenceCoordinator(
            store: store, expectedHouseholdId: s.hhId, householdPublicKey: s.rootPub,
            fetchEvidence: { nonce in
                // First call fails; the second succeeds, proving the stable
                // binding survived the degrade.
                if failing.callCount == 0 {
                    failing.record()
                    throw RosterEvidenceClientError.transportFailed
                }
                return try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.advanceSnapshot)
            },
            probeCurrency: neverProbe(recorder),
            nonceProvider: { self.testNonce }, now: { self.fixedNow })

        guard case .degraded(let reason, let lastKnown) = await coordinator.refresh() else {
            Issue.record("expected degraded"); return
        }
        #expect(reason == .transport)
        #expect(lastKnown?.checkpointSequence == 1)

        // The persisted current was never seeded away, so the next refresh
        // advances from it on the stable-binding path.
        guard case .current(let advanced) = await coordinator.refresh() else {
            Issue.record("expected current after retry"); return
        }
        #expect(advanced.checkpointSequence == 2)
        #expect(recorder.callCount == 0)
    }

    @Test func persistFailureDegradesToStorageAndNeverPublishesCandidate() async throws {
        let s = try scenario(hhId: "hh_persistfail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.advanceSnapshot)
            },
            probe: neverProbe(recorder))

        storage.setFailSave(true)
        guard case .degraded(let reason, let lastKnown) = await coordinator.refresh() else {
            Issue.record("expected degraded"); return
        }
        #expect(reason == .storage)
        // The candidate (seq 2) is never published; only the pre-commit value.
        #expect(lastKnown?.checkpointSequence == 1)
        #expect(recorder.callCount == 0)

        // The store never published the candidate either.
        if case .current(let live) = await store.load() {
            #expect(live.projection.checkpointSequence == 1)
        }
    }

    /// `.anchorMissing` is an availability/ordering condition, not a claim about
    /// the bytes, so it must degrade rather than accuse. Forced for real: the
    /// injected fetch runs after `refresh()` has chosen its basis from the
    /// stored current and before `commitCurrent`, so clearing the account and
    /// reloading there makes the store `.absent` underneath an otherwise
    /// perfectly valid candidate.
    @Test func anchorMissingBetweenLoadAndCommitDegradesToStorageNotTamper() async throws {
        let s = try scenario(hhId: "hh_anchorgone")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()

        let coordinator = RosterEvidenceCoordinator(
            store: store, expectedHouseholdId: s.hhId, householdPublicKey: s.rootPub,
            fetchEvidence: { nonce in
                storage.delete(account: self.account)
                await store.reload()
                return try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.advanceSnapshot)
            },
            probeCurrency: neverProbe(recorder),
            nonceProvider: { self.testNonce }, now: { self.fixedNow })

        guard case .degraded(let reason, let lastKnown) = await coordinator.refresh() else {
            Issue.record("expected degraded(.storage) — never tamper or re-pair")
            return
        }
        #expect(reason == .storage)
        // The projection valid when the basis was chosen (seq 1), never the
        // verified candidate (seq 2).
        #expect(lastKnown?.checkpointSequence == 1)
        #expect(recorder.callCount == 0)

        // The candidate was neither published nor persisted.
        #expect(await store.load() == .absent)
        let reloaded = makeStore(s, storage: storage)
        #expect(await reloaded.load() == .absent)

        // The next refresh re-reads the store and follows the correct branch:
        // absent with no rejection is `.unknown`, never tamper.
        #expect(await coordinator.refresh() == .unknown)
    }

    // MARK: - Tamper: local classification, zero probe

    @Test func corruptStoredStateRefreshesToTamperWithoutFetching() async throws {
        let s = try scenario(hhId: "hh_corrupt")
        let storage = FakeSecureStorage()
        _ = try await seededCurrent(s, storage: storage)
        storage.overwrite(Data([0x00, 0x01, 0x02]), account: account)

        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: makeStore(s, storage: storage),
            fetch: { _ in
                Issue.record("must not fetch without an anchor")
                throw RosterEvidenceClientError.transportFailed
            },
            probe: neverProbe(recorder))

        #expect(
            await coordinator.refresh()
                == .tamperSuspected(.storedStateRejected(.blobUnreadable)))
        #expect(recorder.callCount == 0)
    }

    @Test func signatureFailureIsTamperAndIssuesNoProbe() async throws {
        let s = try scenario(hhId: "hh_sigfail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.advanceSnapshot,
                    corruptSignature: true)
            },
            probe: neverProbe(recorder))

        #expect(
            await coordinator.refresh()
                == .tamperSuspected(.evidence(.signatureInvalid)))
        // Only anchorMismatch may probe.
        #expect(recorder.callCount == 0)
    }

    @Test func nonceMismatchIsTamperAndIssuesNoProbe() async throws {
        let s = try scenario(hhId: "hh_noncefail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { _ in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: Data(repeating: 0x11, count: 32),
                    outcome: "available", snapshotBody: s.advanceSnapshot)
            },
            probe: neverProbe(recorder))

        #expect(
            await coordinator.refresh() == .tamperSuspected(.evidence(.nonceMismatch)))
        #expect(recorder.callCount == 0)
    }

    @Test func floorRollbackIsTransitionTamperAndIssuesNoProbe() async throws {
        let s = try scenario(hhId: "hh_rollback")
        let storage = FakeSecureStorage()
        let store = makeStore(s, storage: storage)
        try await store.seedPendingAnchor(qrAnchorFingerprint: s.signerFingerprint)
        let binding = try RosterSignerBinding(
            hhId: s.hhId, mId: s.signerMId,
            machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint)
        // Land the seq-2 advance first, then serve the older genesis snapshot.
        try await store.commitCurrent(
            signerBinding: binding, canonicalSnapshotBody: canonicalBody(s.advanceSnapshot))

        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in
                try self.evidenceResponse(
                    machinePriv: s.signerKey, mId: s.signerMId,
                    machineCert: s.signerCert, machineCertFingerprint: s.signerFingerprint,
                    nonce: nonce, outcome: "available", snapshotBody: s.genesisSnapshot)
            },
            probe: neverProbe(recorder))

        #expect(
            await coordinator.refresh()
                == .tamperSuspected(.evidence(.transitionInvalid)))
        #expect(recorder.callCount == 0)
    }

    // MARK: - anchorMismatch probe

    /// The signer's cert is rotated so the stable binding no longer matches,
    /// and the currency endpoint returns a valid owner-signed revocation for
    /// exactly that machine in the stored epoch.
    private func rotatedSignerResponse(
        _ s: Scenario, nonce: Data
    ) throws -> RosterEvidenceResponse {
        let root = try rootKey()
        let (rotatedCert, rotatedMId, _, rotatedFp) = try machineCert(
            root: root, hhId: s.hhId, machinePriv: s.signerKey,
            hostname: "mac-alpha-rotated", issuedAt: 1_000)
        return try evidenceResponse(
            machinePriv: s.signerKey, mId: rotatedMId,
            machineCert: rotatedCert, machineCertFingerprint: rotatedFp,
            nonce: nonce, outcome: "available", snapshotBody: s.genesisSnapshot)
    }

    @Test func anchorMismatchWithValidRevokedTombstoneRequiresRePairing() async throws {
        let s = try scenario(hhId: "hh_repair")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let before = await store.load()
        let recorder = ProbeRecorder()

        let (_, tombstone) = try makeRevocation(
            owner: s.ownerKey, mId: s.signerMId,
            mPub: s.signerKey.publicKey.compressedRepresentation,
            mCertFingerprint: s.signerFingerprint,
            hhId: s.hhId, epoch: s.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: 1_000,
            pId: s.ownerPId, pCertFingerprint: s.ownerFingerprint, pCert: s.ownerCert)

        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { machineId in
                recorder.record()
                #expect(machineId == s.signerMId)
                return RosterCurrencyResponse(
                    v: 1, outcome: "revoked", member: nil, tombstone: tombstone)
            })

        #expect(
            await coordinator.refresh() == .requiresRePairing(retiredMId: s.signerMId))
        // Exactly one probe.
        #expect(recorder.callCount == 1)
        // The store is preserved: re-pairing is the user's decision.
        #expect(await store.load() == before)
    }

    @Test func anchorMismatchWithActiveOutcomeIsTamper() async throws {
        let s = try scenario(hhId: "hh_active")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let before = await store.load()
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                return RosterCurrencyResponse(
                    v: 1, outcome: "active",
                    member: RosterCurrencyMember(
                        mId: s.signerMId,
                        mPub: s.signerKey.publicKey.compressedRepresentation,
                        machineCert: s.signerCert,
                        machineCertFingerprint: s.signerFingerprint),
                    tombstone: nil)
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
        #expect(await store.load() == before)
    }

    @Test func anchorMismatchWithForgedTombstoneSignatureIsTamper() async throws {
        let s = try scenario(hhId: "hh_forged")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()

        // Signed by a machine key, not the owner.
        let (_, forged) = try makeRevocation(
            owner: s.signerKey, mId: s.signerMId,
            mPub: s.signerKey.publicKey.compressedRepresentation,
            mCertFingerprint: s.signerFingerprint,
            hhId: s.hhId, epoch: s.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: 1_000,
            pId: s.ownerPId, pCertFingerprint: s.ownerFingerprint, pCert: s.ownerCert)

        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                return RosterCurrencyResponse(
                    v: 1, outcome: "revoked", member: nil, tombstone: forged)
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
    }

    @Test func anchorMismatchWithForeignTargetTombstoneIsTamper() async throws {
        let s = try scenario(hhId: "hh_foreign")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()

        // A genuine owner-signed revocation, but for the OTHER machine.
        let (_, otherTombstone) = try makeRevocation(
            owner: s.ownerKey, mId: s.otherMId, mPub: s.otherPub,
            mCertFingerprint: s.otherFingerprint,
            hhId: s.hhId, epoch: s.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: 1_000,
            pId: s.ownerPId, pCertFingerprint: s.ownerFingerprint, pCert: s.ownerCert)

        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                return RosterCurrencyResponse(
                    v: 1, outcome: "revoked", member: nil, tombstone: otherTombstone)
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
    }

    /// Same household, same owner, valid signature — but a different epoch is a
    /// different lineage and must never authorise re-pairing.
    @Test func anchorMismatchWithForeignEpochTombstoneIsTamper() async throws {
        let s = try scenario(hhId: "hh_epoch")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()

        let (_, otherEpochTombstone) = try makeRevocation(
            owner: s.ownerKey, mId: s.signerMId,
            mPub: s.signerKey.publicKey.compressedRepresentation,
            mCertFingerprint: s.signerFingerprint,
            hhId: s.hhId, epoch: Data(repeating: 0xE7, count: 32), sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: 1_000,
            pId: s.ownerPId, pCertFingerprint: s.ownerFingerprint, pCert: s.ownerCert)

        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                return RosterCurrencyResponse(
                    v: 1, outcome: "revoked", member: nil, tombstone: otherEpochTombstone)
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
    }

    @Test func anchorMismatchWithCurrencyTransportFailureIsTamper() async throws {
        let s = try scenario(hhId: "hh_probefail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let before = await store.load()
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                throw RosterCurrencyClientError.transportFailed
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
        #expect(await store.load() == before)
    }

    @Test func anchorMismatchWithCurrencyUnavailableIsTamper() async throws {
        let s = try scenario(hhId: "hh_probeunavail")
        let storage = FakeSecureStorage()
        let store = try await seededCurrent(s, storage: storage)
        let recorder = ProbeRecorder()
        let coordinator = makeCoordinator(
            s, store: store,
            fetch: { nonce in try self.rotatedSignerResponse(s, nonce: nonce) },
            probe: { _ in
                recorder.record()
                return RosterCurrencyResponse(
                    v: 1, outcome: "unavailable_owner_authority",
                    member: nil, tombstone: nil)
            })

        #expect(await coordinator.refresh() == .tamperSuspected(.anchorUnproven))
        #expect(recorder.callCount == 1)
    }
}
