import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

struct RosterEvidenceVerifierTests {
    // MARK: - Deterministic keys

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

    private let testNonce = Data(repeating: 0xAB, count: 32)

    // MARK: - CBOR helpers

    private func certSigner(_ map: [String: HouseholdCBORValue], with key: P256.Signing.PrivateKey) throws -> Data {
        var unsigned = [String: HouseholdCBORValue]()
        for (k, v) in map where k != "signature" { unsigned[k] = v }
        let toSign = HouseholdCBOR.encode(.map(unsigned))
        let sig = try key.signature(for: toSign)
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
        let fp = Data(SHA256.hash(data: cert))
        return (cert, mId, mPub, fp)
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
        let fp = Data(SHA256.hash(data: cert))
        return (cert, pId, fp)
    }

    private func memberMap(
        mId: String, mPub: Data, machineCert: Data, fingerprint: Data
    ) -> [String: HouseholdCBORValue] {
        [
            "m_id": .text(mId),
            "m_pub": .bytes(mPub),
            "machine_cert": .bytes(machineCert),
            "machine_cert_fingerprint": .bytes(fingerprint),
        ]
    }

    private func makeCheckpoint(
        owner: P256.Signing.PrivateKey, hhId: String, epoch: Data,
        seq: UInt64, prevHash: Data, eventSeq: UInt64, eventHead: Data,
        meshDigest: Data, issuedAt: UInt64, notAfter: UInt64,
        pId: String, pCertFingerprint: Data,
        active: [[String: HouseholdCBORValue]], revocations: [[String: HouseholdCBORValue]],
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
        let toSign = RosterAuthorityVerifier.checkpointDomain + canonicalUnsigned
        let sig = try owner.signature(for: toSign)
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
        let toSign = RosterAuthorityVerifier.revocationDomain + canonicalUnsigned
        let sig = try owner.signature(for: toSign)
        revMap["signature"] = .bytes(sig.rawRepresentation)
        return (revMap, eventHash)
    }

    private func snapshotBodyMap(_ snapshot: RosterEvidenceSnapshotBody, includeFloor: Bool) -> [String: HouseholdCBORValue] {
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

    private func computeStateEvidenceDigest(snapshot: RosterEvidenceSnapshotBody) -> Data {
        let body = HouseholdCBOR.encode(.map(snapshotBodyMap(snapshot, includeFloor: false)))
        return Data(SHA256.hash(data: RosterEvidenceVerifier.evidenceDomain + body))
    }

    private func computeFullSnapshotDigest(snapshot: RosterEvidenceSnapshotBody) -> Data {
        let body = HouseholdCBOR.encode(.map(snapshotBodyMap(snapshot, includeFloor: true)))
        return Data(SHA256.hash(data: RosterEvidenceVerifier.snapshotDomain + body))
    }

    private func evidenceResponse(
        machinePriv: P256.Signing.PrivateKey, mId: String,
        machineCert: Data, machineCertFingerprint: Data,
        nonce: Data, outcome: String,
        snapshotBody: RosterEvidenceSnapshotBody?,
        stateEvidenceDigest: Data?, fullSnapshotDigest: Data?
    ) throws -> RosterEvidenceResponse {
        var unsigned: [String: HouseholdCBORValue] = [
            "client_nonce": .bytes(nonce), "outcome": .text(outcome),
            "signer_m_id": .text(mId),
            "signer_machine_cert": .bytes(machineCert),
            "signer_machine_cert_fingerprint": .bytes(machineCertFingerprint),
            "v": .unsigned(1),
        ]
        if let snap = snapshotBody {
            unsigned["snapshot_body"] = .map(snapshotBodyMap(snap, includeFloor: true))
        }
        if let d = stateEvidenceDigest { unsigned["state_evidence_digest"] = .bytes(d) }
        if let d = fullSnapshotDigest { unsigned["full_snapshot_digest"] = .bytes(d) }
        let preimage = RosterEvidenceVerifier.evidenceDomain + HouseholdCBOR.encode(.map(unsigned))
        let sig = try machinePriv.signature(for: preimage)
        return RosterEvidenceResponse(
            v: 1, outcome: outcome, snapshotBody: snapshotBody,
            stateEvidenceDigest: stateEvidenceDigest,
            fullSnapshotDigest: fullSnapshotDigest,
            signerMId: mId, signerMachineCert: machineCert,
            signerMachineCertFingerprint: machineCertFingerprint,
            clientNonce: nonce, signature: sig.rawRepresentation
        )
    }

    // MARK: - verifySignerPinResponse

    @Test func signerPinSuccess() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_pin"; let issuedAt: UInt64 = 1000
        let mKey = try machine1Key()
        let (cert, mId, _, fp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-pin", issuedAt: issuedAt)
        let unsigned: [String: HouseholdCBORValue] = [
            "hh_id": .text(hhId), "m_id": .text(mId), "machine_cert": .bytes(cert),
            "machine_cert_fingerprint": .bytes(fp), "client_nonce": .bytes(testNonce), "v": .unsigned(1),
        ]
        let pinPreimage = RosterEvidenceVerifier.signerPinDomain + HouseholdCBOR.encode(.map(unsigned))
        let sig = try mKey.signature(for: pinPreimage)
        let response = RosterSignerPinResponse(v: 1, clientNonce: testNonce, hhId: hhId, mId: mId, machineCert: cert, machineCertFingerprint: fp, signature: sig.rawRepresentation)
        let binding = try RosterEvidenceVerifier.verifySignerPinResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchorFingerprint: fp)
        #expect(binding.mId == mId)
    }

    @Test func signerPinNonceMismatch() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_pinerr"; let issuedAt: UInt64 = 1000
        let mKey = try machine1Key()
        let (cert, mId, _, fp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-pinerr", issuedAt: issuedAt)
        let unsigned: [String: HouseholdCBORValue] = [
            "hh_id": .text(hhId), "m_id": .text(mId), "machine_cert": .bytes(cert),
            "machine_cert_fingerprint": .bytes(fp), "client_nonce": .bytes(testNonce), "v": .unsigned(1),
        ]
        let pinPreimage = RosterEvidenceVerifier.signerPinDomain + HouseholdCBOR.encode(.map(unsigned))
        let sig = try mKey.signature(for: pinPreimage)
        let response = RosterSignerPinResponse(v: 1, clientNonce: testNonce, hhId: hhId, mId: mId, machineCert: cert, machineCertFingerprint: fp, signature: sig.rawRepresentation)
        #expect(throws: RosterEvidenceError.nonceMismatch) {
            try RosterEvidenceVerifier.verifySignerPinResponse(response: response, expectedNonce: Data(repeating: 0xFF, count: 32), expectedHouseholdId: hhId, householdPublicKey: rootPub, anchorFingerprint: fp)
        }
    }

    @Test func signerPinSignatureInvalid() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_pinsig"; let issuedAt: UInt64 = 1000
        let mKey = try machine2Key()
        let (cert, mId, _, fp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-pinsig", issuedAt: issuedAt)
        let wrongKey = try machine1Key()
        let unsigned: [String: HouseholdCBORValue] = [
            "hh_id": .text(hhId), "m_id": .text(mId), "machine_cert": .bytes(cert),
            "machine_cert_fingerprint": .bytes(fp), "client_nonce": .bytes(testNonce), "v": .unsigned(1),
        ]
        let pinPreimage = RosterEvidenceVerifier.signerPinDomain + HouseholdCBOR.encode(.map(unsigned))
        let sig = try wrongKey.signature(for: pinPreimage)
        let response = RosterSignerPinResponse(v: 1, clientNonce: testNonce, hhId: hhId, mId: mId, machineCert: cert, machineCertFingerprint: fp, signature: sig.rawRepresentation)
        #expect(throws: RosterEvidenceError.signatureInvalid) { try RosterEvidenceVerifier.verifySignerPinResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchorFingerprint: fp) }
    }

    // MARK: - Available NoGenesis (QR)

    @Test func availableNoGenesisQR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_ngqr"; let issuedAt: UInt64 = 1000
        let mKey = try machine1Key()
        let (cert, mId, _, fp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-ngqr", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let evDigest = computeStateEvidenceDigest(snapshot: snap)
        let snapDigest = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: cert, machineCertFingerprint: fp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest)
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: fp), previousProjection: nil)
        guard case .available(let evidence) = outcome else { Issue.record("expected available"); return }
        #expect(evidence.projection.stateKind == VerifiedRosterProjection.stateKindNoGenesis)
        #expect(evidence.projection.activeMembers.isEmpty)
        #expect(evidence.projection.genesisCheckpointHash == nil)
        #expect(evidence.projection.eventHashes.isEmpty)
        #expect(evidence.projection.eventHeadHash == RosterAuthorityVerifier.zeroHash32)
    }

    // MARK: - Available Accepted (synthetic)

    @Test func availableAcceptedGenesisQR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_ac1"; let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-ac1", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let evDigest = computeStateEvidenceDigest(snapshot: snap)
        let snapDigest = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest)
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(ev.projection.checkpointSequence == 1)
        #expect(ev.projection.activeMembers.count == 1)
        #expect(ev.projection.activeMembers[0].mId == mId)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        #expect(ev.projection.genesisCheckpointHash == genesis.checkpointHash)
        #expect(ev.projection.eventHashes.isEmpty)
        #expect(ev.projection.eventHeadHash == RosterAuthorityVerifier.zeroHash32)
    }

    // MARK: - Available Accepted seq>1 (advance)

    @Test func availableAcceptedSeq2QR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_ac2"; let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-ac2a", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-ac2b", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let refreshRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: refreshRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let evDigest = computeStateEvidenceDigest(snapshot: snap)
        let snapDigest = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest)
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(ev.projection.checkpointSequence == 2)
        #expect(ev.projection.genesisCheckpointHash == genesis.checkpointHash)
        #expect(ev.projection.eventHashes == [revHash])
        #expect(ev.projection.eventHeadHash == revHash)
        #expect(ev.projection.tombstones.count == 1)
        #expect(ev.projection.activeMembers.count == 1)
        #expect(ev.projection.activeMembers[0].mId == m1Id)
    }

    // MARK: - Unavailable

    @Test func unavailableQR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_unav"; let issuedAt: UInt64 = 1000
        let mKey = try machine1Key()
        let (cert, mId, _, fp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-unav", issuedAt: issuedAt)
        for o in ["unavailable_clock_state", "unavailable_owner_authority", "unavailable_checkpoint_stale"] {
            let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: cert, machineCertFingerprint: fp, nonce: testNonce, outcome: o, snapshotBody: nil, stateEvidenceDigest: nil, fullSnapshotDigest: nil)
            let result = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: fp), previousProjection: nil)
            guard case .unavailable(_, let out) = result, out == o else { Issue.record("unavailable(\(o))"); return }
        }
    }

    // MARK: - CheckpointFork (real structural divergence)

    @Test func availableCheckpointForkQR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_cpf"; let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-cpf", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt)
        let evDigest = computeStateEvidenceDigest(snapshot: snap)
        let snapDigest = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest)
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.stateKind == VerifiedRosterProjection.stateKindCheckpointFork)
        #expect(ev.projection.conflictingCheckpointBytes != nil)
    }

    // MARK: - EventFork (real structural divergence)

    @Test func availableEventForkQR() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_evf"; let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-evf1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-evf2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let refreshRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let accepted = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: refreshRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)

        let (otherRevMap, otherRevHash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: accepted.checkpointHash, eventSeq: 1, eventHead: otherRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [otherRevMap], pCert: oCert)

        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: refreshRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 10)
        let evDigest = computeStateEvidenceDigest(snapshot: snap)
        let snapDigest = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: evDigest, fullSnapshotDigest: snapDigest)
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(ev.projection.conflictingCheckpointBytes != nil)
    }

    // MARK: - Terminal fork absorbing (stable binding)

    @Test func terminalForkReplayAccepted() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tfrp"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-tfrp", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let forkSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt)
        let forkResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap))
        let forkOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let forkProj) = forkOutcome else { Issue.record("expected fork available"); return }
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let replaySnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 5)
        let replayResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: replaySnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: replaySnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: replaySnap))
        let replayOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: replayResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        guard case .available(let accepted) = replayOutcome else { Issue.record("expected available on replay"); return }
        #expect(accepted.projection.stateKind == VerifiedRosterProjection.stateKindCheckpointFork)
        #expect(accepted.projection.checkpointBytes == forkProj.projection.checkpointBytes)
        #expect(accepted.projection.conflictingCheckpointBytes == forkProj.projection.conflictingCheckpointBytes)
        #expect(accepted.projection.genesisCheckpointHash == forkProj.projection.genesisCheckpointHash)
        // The fork branch adds no event guard of its own: the genesis, accepted and
        // conflicting pins already fix the whole chain, so equality of the event list is
        // implied. Asserted here rather than enforced in code, by design.
        #expect(accepted.projection.eventHashes == forkProj.projection.eventHashes)
    }

    @Test func terminalForkFloorRollbackRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tfrb"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key(); let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-tfrb", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let forkSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt)
        let forkResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap))
        let forkOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let forkProj) = forkOutcome else { Issue.record("expected fork"); return }
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let rollSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: 500)
        let rollResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: rollSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: rollSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: rollSnap))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: rollResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        }
    }

    @Test func terminalForkDifferentKindRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tfdk"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key(); let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-tfdk", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let forkSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt)
        let forkResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap))
        let forkOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let forkProj) = forkOutcome else { Issue.record("expected fork"); return }
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let acceptedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt + 5)
        let acceptedResponse = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: acceptedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: acceptedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: acceptedSnap))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: acceptedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        }
    }

    @Test func terminalForkDifferentConflictingRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tfdc"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-tfdc", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflicting1 = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let conflicting2 = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xEE, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let forkSnap1 = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflicting1, floorSecs: issuedAt)
        let forkResp1 = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap1, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap1), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap1))
        let forkResult1 = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResp1, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil)
        guard case .available(let forkProj) = forkResult1 else { Issue.record("expected fork"); return }
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let forkSnap2 = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: conflicting2, floorSecs: issuedAt + 5)
        let forkResp2 = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap2, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap2), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap2))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResp2, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        }
    }

    @Test func terminalCheckpointForkChangedAcceptedRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_cpfca"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-cpfca1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-cpfca2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedARaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedBRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xEE, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let forkSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedARaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 10)
        let forkResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap))
        let forkOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let forkProj) = forkOutcome else { Issue.record("expected checkpoint fork"); return }
        #expect(forkProj.projection.stateKind == VerifiedRosterProjection.stateKindCheckpointFork)
        #expect(forkProj.projection.checkpointSequence == 2)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let changedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedBRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 15)
        let changedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: changedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: changedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: changedSnap))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: changedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        }
    }

    @Test func terminalEventForkReplayAccepted() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_evfrp"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-evfrp1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-evfrp2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let accepted = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: acceptedRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let (otherRevMap, otherRevHash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: accepted.checkpointHash, eventSeq: 1, eventHead: otherRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [otherRevMap], pCert: oCert)
        let forkSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 10)
        let forkResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: forkSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: forkSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: forkSnap))
        let forkOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: forkResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let forkProj) = forkOutcome else { Issue.record("expected event fork"); return }
        #expect(forkProj.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let replaySnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 15)
        let replayResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: replaySnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: replaySnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: replaySnap))
        let replayOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: replayResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: forkProj.projection)
        guard case .available(let replay) = replayOutcome else { Issue.record("expected available on replay"); return }
        #expect(replay.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(replay.projection.checkpointBytes == forkProj.projection.checkpointBytes)
        #expect(replay.projection.conflictingCheckpointBytes == forkProj.projection.conflictingCheckpointBytes)
        #expect(replay.projection.genesisCheckpointHash == forkProj.projection.genesisCheckpointHash)
        #expect(replay.projection.eventHashes == forkProj.projection.eventHashes)
        #expect(replay.projection.floorSecs == issuedAt + 15)
    }

    // MARK: - Stable binding (corrected)

    @Test func availableAcceptedStableBinding() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_stbl"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-stbl", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: 500, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(ev.projection.activeMembers[0].mId == mId)
    }

    @Test func stableBindingWithoutPreviousFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_stblnp"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-stblnp", issuedAt: issuedAt)
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: nil)
        }
    }

    @Test func stableBindingAnchorMismatchWrongMId() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_stblam"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key(); let otherKey = try machine2Key()
        let (mCert, trueMId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-stblam1", issuedAt: issuedAt)
        let (_, wrongMId, _, _) = try machineCert(root: root, hhId: hhId, machinePriv: otherKey, hostname: "mac-stblam2", issuedAt: issuedAt)
        let mEntry = memberMap(mId: trueMId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let stable = try RosterSignerBinding(hhId: hhId, mId: wrongMId, machineCert: mCert, machineCertFingerprint: mFp)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: 500, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: mKey, mId: trueMId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev)
        }
    }

    // MARK: - Floor transition (stable binding)

    @Test func transitionAcceptedFloorAdvances() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tradv"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-tradv", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: 500, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: 1000)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        let outcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev)
        guard case .available(let ev) = outcome else { Issue.record("expected available"); return }
        #expect(ev.projection.floorSecs >= 500)
    }

    @Test func transitionFloorRollbackRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_trrb"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let mKey = try machine1Key()
        let (mCert, mId, mPub, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-trrb", issuedAt: issuedAt)
        let mEntry = memberMap(mId: mId, mPub: mPub, machineCert: mCert, fingerprint: mFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [mEntry], revocations: [], pCert: oCert)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: 2000, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let stable = try RosterSignerBinding(hhId: hhId, mId: mId, machineCert: mCert, machineCertFingerprint: mFp)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: 500)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev)
        }
    }

    // MARK: - Signer not active member (stable binding)

    @Test func signerNotActiveMemberStableBindingFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_sgnam"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let activeKey = try machine1Key(); let signerKey = try machine2Key()
        let (actCert, actMId, actPub, actFp) = try machineCert(root: root, hhId: hhId, machinePriv: activeKey, hostname: "mac-sgnam1", issuedAt: issuedAt)
        let (sigCert, sigMId, sigPub, sigFp) = try machineCert(root: root, hhId: hhId, machinePriv: signerKey, hostname: "mac-sgnam2", issuedAt: issuedAt)
        let activeEntry = memberMap(mId: actMId, mPub: actPub, machineCert: actCert, fingerprint: actFp)
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: [activeEntry], revocations: [], pCert: oCert)
        let stable = try RosterSignerBinding(hhId: hhId, mId: sigMId, machineCert: sigCert, machineCertFingerprint: sigFp)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: 500, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: signerKey, mId: sigMId, machineCert: sigCert, machineCertFingerprint: sigFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev)
        }
    }

    // MARK: - Previous Accepted (stable binding)

    @Test func previousAcceptedUnavailableWithExactSignerSucceeds() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_pauna"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-pauna1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-pauna2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let acceptedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: acceptedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: acceptedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: acceptedSnap))
        let acceptedOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: acceptedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = acceptedOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.tombstones == [m2Id])
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let unavailableResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "unavailable_clock_state", snapshotBody: nil, stateEvidenceDigest: nil, fullSnapshotDigest: nil)
        let result = try RosterEvidenceVerifier.verifyEvidenceResponse(response: unavailableResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        guard case .unavailable(let binding, let out) = result else { Issue.record("expected unavailable"); return }
        #expect(binding == stable)
        #expect(binding.hhId == hhId)
        #expect(binding.mId == m1Id)
        #expect(binding.machineCert == m1Cert)
        #expect(binding.machineCertFingerprint == m1Fp)
        #expect(out == "unavailable_clock_state")
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.checkpointBytes == acceptedRaw)
    }

    @Test func previousAcceptedSignerNotMemberFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_pasnm"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-pasnm1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-pasnm2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let acceptedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: acceptedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: acceptedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: acceptedSnap))
        let acceptedOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: acceptedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = acceptedOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.member(for: m2Id) == nil)
        #expect(prev.projection.isRevoked(m2Id))
        let stableM2 = try RosterSignerBinding(hhId: hhId, mId: m2Id, machineCert: m2Cert, machineCertFingerprint: m2Fp)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 15)
        let m2Response = try evidenceResponse(machinePriv: m2Key, mId: m2Id, machineCert: m2Cert, machineCertFingerprint: m2Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: m2Response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stableM2), previousProjection: prev.projection)
        }
    }

    @Test func previousAcceptedSignerCertRotatedFails() throws {
        // Load-bearing: same machine key, therefore the same m_id and m_pub, but two
        // distinct valid machine certs under the same household root differing only in
        // hostname. The previous projection pins certA; the response and the stable
        // binding both carry certB. m_id and m_pub match, so this reaches the full
        // member-binding comparison and must be rejected there on cert bytes and
        // fingerprint, not on a missing member.
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_pascr"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1CertA, m1IdA, m1PubA, m1FpA) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-pascr1a", issuedAt: issuedAt)
        let (m1CertB, m1IdB, m1PubB, m1FpB) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-pascr1b", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-pascr2", issuedAt: issuedAt)
        #expect(m1IdB == m1IdA)
        #expect(m1PubB == m1PubA)
        #expect(m1CertB != m1CertA)
        #expect(m1FpB != m1FpA)
        let m1Entry = memberMap(mId: m1IdA, mPub: m1PubA, machineCert: m1CertA, fingerprint: m1FpA)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let acceptedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1IdA, machineCert: m1CertA, machineCertFingerprint: m1FpA, nonce: testNonce, outcome: "available", snapshotBody: acceptedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: acceptedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: acceptedSnap))
        let acceptedOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: acceptedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1FpA), previousProjection: nil)
        guard case .available(let prev) = acceptedOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.member(for: m1IdA)?.certFingerprint == m1FpA)
        #expect(prev.projection.member(for: m1IdA)?.certBytes == m1CertA)
        let stableB = try RosterSignerBinding(hhId: hhId, mId: m1IdB, machineCert: m1CertB, machineCertFingerprint: m1FpB)
        let rotatedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1IdB, machineCert: m1CertB, machineCertFingerprint: m1FpB, nonce: testNonce, outcome: "unavailable_clock_state", snapshotBody: nil, stateEvidenceDigest: nil, fullSnapshotDigest: nil)
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: rotatedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stableB), previousProjection: prev.projection)
        }
    }

    @Test func previousAcceptedHouseholdMismatchFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhA = "hh_pahma"; let hhB = "hh_pahmb"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCertB, pIdB, oFpB) = try makeOwnerCert(root: root, owner: owner, hhId: hhB, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1CertB, m1Id, m1PubB, m1FpB) = try machineCert(root: root, hhId: hhB, machinePriv: m1Key, hostname: "mac-pahmb1", issuedAt: issuedAt)
        let (m2CertB, m2Id, m2PubB, m2FpB) = try machineCert(root: root, hhId: hhB, machinePriv: m2Key, hostname: "mac-pahmb2", issuedAt: issuedAt)
        let m1EntryB = memberMap(mId: m1Id, mPub: m1PubB, machineCert: m1CertB, fingerprint: m1FpB)
        let m2EntryB = memberMap(mId: m2Id, mPub: m2PubB, machineCert: m2CertB, fingerprint: m2FpB)
        let genesisActiveB = [m1EntryB, m2EntryB].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRawB = try makeCheckpoint(owner: owner, hhId: hhB, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pIdB, pCertFingerprint: oFpB, active: genesisActiveB, revocations: [], pCert: oCertB)
        let genesisB = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRawB, expectedHouseholdId: hhB, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMapB, revHashB) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2PubB, mCertFingerprint: m2FpB, hhId: hhB, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pIdB, pCertFingerprint: oFpB, pCert: oCertB)
        let acceptedRawB = try makeCheckpoint(owner: owner, hhId: hhB, epoch: epoch, seq: 2, prevHash: genesisB.checkpointHash, eventSeq: 1, eventHead: revHashB, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pIdB, pCertFingerprint: oFpB, active: [m1EntryB], revocations: [revMapB], pCert: oCertB)
        let snapB = RosterEvidenceSnapshotBody(v: 1, hhId: hhB, stateKind: 1, genesisCheckpoint: genesisRawB, acceptedCheckpoint: acceptedRawB, predecessorCheckpoint: genesisRawB, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let responseB = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1CertB, machineCertFingerprint: m1FpB, nonce: testNonce, outcome: "available", snapshotBody: snapB, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snapB), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snapB))
        let outcomeB = try RosterEvidenceVerifier.verifyEvidenceResponse(response: responseB, expectedNonce: testNonce, expectedHouseholdId: hhB, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1FpB), previousProjection: nil)
        guard case .available(let prevB) = outcomeB else { Issue.record("expected accepted previous"); return }
        #expect(prevB.projection.hhId == hhB)
        #expect(prevB.projection.checkpointSequence == 2)
        #expect(prevB.projection.member(for: m1Id) != nil)
        let (m1CertA, m1IdA, _, m1FpA) = try machineCert(root: root, hhId: hhA, machinePriv: m1Key, hostname: "mac-pahma1", issuedAt: issuedAt)
        #expect(m1IdA == m1Id)
        let stableA = try RosterSignerBinding(hhId: hhA, mId: m1IdA, machineCert: m1CertA, machineCertFingerprint: m1FpA)
        let responseA = try evidenceResponse(machinePriv: m1Key, mId: m1IdA, machineCert: m1CertA, machineCertFingerprint: m1FpA, nonce: testNonce, outcome: "unavailable_checkpoint_stale", snapshotBody: nil, stateEvidenceDigest: nil, fullSnapshotDigest: nil)
        #expect(throws: RosterEvidenceError.anchorMismatch) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: responseA, expectedNonce: testNonce, expectedHouseholdId: hhA, householdPublicKey: rootPub, anchor: .stableBinding(stableA), previousProjection: prevB.projection)
        }
    }

    @Test func previousAcceptedSequenceRollbackRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_pasrb"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-pasrb1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-pasrb2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let acceptedResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: acceptedSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: acceptedSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: acceptedSnap))
        let acceptedOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: acceptedResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = acceptedOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.member(for: m1Id) != nil)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let rollbackSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: genesisRaw, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let rollbackResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: rollbackSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: rollbackSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: rollbackSnap))
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: rollbackResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    // MARK: - Accepted transition matrix (stable binding)

    // Every guard in the Accepted branch of validateAvailableTransition throws the
    // same .transitionInvalid, so no assertion can name the guard that fired. Each
    // test below therefore runs the SAME candidate response twice: first with a QR
    // pin and no previous, asserting .available plus the projected fields, which
    // proves the candidate is intrinsically valid and buildProjection succeeded; then
    // with the stable binding and the Accepted previous, where exactly one invariant
    // is violated by construction. Without the control call the negative would be
    // vacuous: an invalid candidate also yields .transitionInvalid.

    @Test func transitionPreviousAcceptedCandidateNoGenesisRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpang"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpang1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpang2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        #expect(prev.projection.floorSecs == issuedAt + 10)
        #expect(prev.projection.member(for: m1Id) != nil)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindNoGenesis)
        #expect(control.projection.checkpointSequence == nil)
        #expect(control.projection.eventSequence == nil)
        #expect(control.projection.activeMembers.isEmpty)
        #expect(control.projection.floorSecs == issuedAt + 10)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func transitionPreviousAcceptedEpochMismatchRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpaep"
        let epoch = Data(repeating: 0xBB, count: 32)
        let candidateEpoch = Data(repeating: 0xB1, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpaep1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpaep2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.epoch == epoch)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        // A different epoch can only come from a different genesis, so the genesis pin
        // also diverges here. The epoch guard keeps its causality only because it runs
        // before the genesis pin, which is deliberately last in the Accepted case.
        let cGenesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: candidateEpoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let cGenesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cGenesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (cRevMap, cRevHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: candidateEpoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let cSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: candidateEpoch, seq: 2, prevHash: cGenesis.checkpointHash, eventSeq: 1, eventHead: cRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [cRevMap], pCert: oCert)
        let cSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let cSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: candidateEpoch, seq: 3, prevHash: cSeq2.checkpointHash, eventSeq: 1, eventHead: cRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [cRevMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: cGenesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: cSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 1)
        #expect(control.projection.epoch == candidateEpoch)
        #expect(control.projection.ownerCertFingerprint == oFp)
        #expect(control.projection.checkpointBytes == cSeq3Raw)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func transitionPreviousAcceptedOwnerCertMismatchRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        // Second owner identity, root-signed under the same household. The existing
        // makeOwnerCert helper covers this unchanged: a different owner key yields a
        // different p_id and different cert bytes at the same issued_at, so no owner
        // cert timestamp is varied and no new helper is needed.
        let owner2 = try P256.Signing.PrivateKey(rawRepresentation: Data((129...160).map(UInt8.init)))
        let hhId = "hh_tpaow"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let (oCert2, pId2, oFp2) = try makeOwnerCert(root: root, owner: owner2, hhId: hhId, issuedAt: issuedAt)
        #expect(oFp2 != oFp)
        #expect(pId2 != pId)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpaow1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpaow2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.ownerCertFingerprint == oFp)
        #expect(prev.projection.epoch == epoch)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        // The owner cert is embedded in the genesis and the whole chain must share it, so
        // a different owner forces a different genesis and the genesis pin diverges too.
        // The owner guard keeps its causality only by running before the pin, which is
        // deliberately last in the Accepted case.
        let cGenesisRaw = try makeCheckpoint(owner: owner2, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId2, pCertFingerprint: oFp2, active: genesisActive, revocations: [], pCert: oCert2)
        let cGenesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cGenesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (cRevMap, cRevHash) = try makeRevocation(owner: owner2, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId2, pCertFingerprint: oFp2, pCert: oCert2)
        let cSeq2Raw = try makeCheckpoint(owner: owner2, hhId: hhId, epoch: epoch, seq: 2, prevHash: cGenesis.checkpointHash, eventSeq: 1, eventHead: cRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId2, pCertFingerprint: oFp2, active: [m1Entry], revocations: [cRevMap], pCert: oCert2)
        let cSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let cSeq3Raw = try makeCheckpoint(owner: owner2, hhId: hhId, epoch: epoch, seq: 3, prevHash: cSeq2.checkpointHash, eventSeq: 1, eventHead: cRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId2, pCertFingerprint: oFp2, active: [m1Entry], revocations: [cRevMap], pCert: oCert2)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: cGenesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: cSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 1)
        #expect(control.projection.epoch == epoch)
        #expect(control.projection.ownerCertFingerprint == oFp2)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func transitionPreviousAcceptedEventSequenceRollbackRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpaev"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpaev1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpaev2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.eventSequence == 1)
        #expect(prev.projection.tombstones == [m2Id])
        // Candidate chain forgets the revocation entirely: every checkpoint carries
        // event_sequence 0 and the zero head, while advancing over the SAME genesis as
        // the previous roster. Sharing the genesis is load-bearing: it keeps the genesis
        // pin satisfied so that the event-sequence regression is the only invariant that
        // diverges, instead of leaving the outcome ambiguous between the two.
        let cSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let cSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let cSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: cSeq2.checkpointHash, eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: cSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 0)
        #expect(control.projection.epoch == epoch)
        #expect(control.projection.ownerCertFingerprint == oFp)
        #expect(control.projection.tombstones.isEmpty)
        #expect(control.projection.activeMembers.count == 2)
        #expect(control.projection.genesisCheckpointHash == genesis.checkpointHash)
        #expect(control.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func transitionPreviousAcceptedSameSequenceBytesRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpasb"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpasb1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpasb2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        #expect(prev.projection.checkpointBytes == acceptedRaw)
        // Second seq2 over the same genesis, identical to the previous accepted except
        // for mesh_log_digest, which is signature-bound but takes no part in the chain
        // or the projection. Sequence and event sequence tie, so the same-sequence byte
        // equality guard is the only one left to reject it.
        let variantRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        #expect(variantRaw != acceptedRaw)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: variantRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 2)
        #expect(control.projection.eventSequence == 1)
        #expect(control.projection.epoch == epoch)
        #expect(control.projection.ownerCertFingerprint == oFp)
        #expect(control.projection.checkpointBytes == variantRaw)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    // MARK: - Accepted transition matrix, approving paths (stable binding)

    // Counterparts to the negatives above: these exercise the two ways the Accepted
    // branch is allowed to succeed. No extra QR control is needed here, because the
    // previous roster is itself built through a real QR verification and .available on
    // the second round already proves both buildProjection and the transition.

    @Test func transitionPreviousAcceptedSameSequenceReplayAccepted() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpasr"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpasr1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpasr2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        #expect(prev.projection.checkpointBytes == acceptedRaw)
        // Deliberately the same shape as the same-sequence negative, including the
        // floor: the only thing that changes is that the candidate carries the exact
        // accepted bytes instead of a divergent variant. That makes the pair sensitive,
        // since a regression in the byte comparison would flip exactly one of the two.
        let replaySnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let replayResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: replaySnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: replaySnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: replaySnap))
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let replayOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: replayResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        guard case .available(let replay) = replayOutcome else { Issue.record("expected available replay"); return }
        #expect(replay.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(replay.projection.checkpointSequence == 2)
        #expect(replay.projection.eventSequence == 1)
        #expect(replay.projection.checkpointBytes == acceptedRaw)
        #expect(replay.projection.checkpointBytes == prev.projection.checkpointBytes)
        #expect(replay.projection.hhId == prev.projection.hhId)
        #expect(replay.projection.epoch == prev.projection.epoch)
        #expect(replay.projection.ownerCertFingerprint == prev.projection.ownerCertFingerprint)
        #expect(replay.projection.conflictingCheckpointBytes == nil)
        #expect(replay.projection.activeMembers.map(\.mId) == [m1Id])
        #expect(replay.projection.tombstones == [m2Id])
        #expect(replay.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        #expect(replay.projection.genesisCheckpointHash == genesis.checkpointHash)
        #expect(replay.projection.eventHashes == prev.projection.eventHashes)
        #expect(replay.projection.eventHeadHash == prev.projection.eventHeadHash)
        #expect(replay.projection.floorSecs == issuedAt + 10)
    }

    @Test func transitionPreviousAcceptedLinearAdvanceAccepted() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_tpala"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-tpala1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-tpala2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let accepted2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let accepted2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: accepted2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: accepted2Raw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.eventSequence == 1)
        #expect(prev.projection.checkpointBytes == accepted2Raw)
        // Legitimate forward move: sequence 3 chained on accepted2, same epoch, same
        // owner, same single revocation and the same event head, so the event sequence
        // ties and the same-sequence byte guard is never reached.
        let accepted3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: accepted2.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let advanceSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: accepted3Raw, predecessorCheckpoint: accepted2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let advanceResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: advanceSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: advanceSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: advanceSnap))
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let advanceOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: advanceResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        guard case .available(let advanced) = advanceOutcome else { Issue.record("expected available advance"); return }
        #expect(advanced.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(advanced.projection.checkpointSequence == 3)
        #expect(advanced.projection.eventSequence == 1)
        #expect(advanced.projection.checkpointBytes == accepted3Raw)
        #expect(advanced.projection.hhId == prev.projection.hhId)
        #expect(advanced.projection.epoch == prev.projection.epoch)
        #expect(advanced.projection.ownerCertFingerprint == prev.projection.ownerCertFingerprint)
        #expect(advanced.projection.conflictingCheckpointBytes == nil)
        #expect(advanced.projection.activeMembers.map(\.mId) == [m1Id])
        #expect(advanced.projection.tombstones == [m2Id])
        #expect(advanced.projection.floorSecs == issuedAt + 10)
        #expect(advanced.projection.issuedAt == issuedAt + 20)
        #expect(advanced.projection.notAfter == notAfter + 20)
        #expect(advanced.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        #expect(advanced.projection.genesisCheckpointHash == genesis.checkpointHash)
        #expect(advanced.projection.eventHashes == prev.projection.eventHashes)
        #expect(advanced.projection.eventHeadHash == prev.projection.eventHeadHash)
    }

    // MARK: - EventFork transition matrix (stable binding)

    @Test func terminalEventForkKindMismatchRejected() throws {
        // :317 is isolated BY ORDER only, and that limit is structural, not a shortcut.
        // The state kind is a function of the accepted/conflicting pair: turning the
        // candidate into a CheckpointFork instead of an EventFork requires changing at
        // least one of the two raws, so a byte guard always stands right behind the kind
        // guard as a competitor. Here the accepted raw is kept byte-identical, so the
        // competitor is :322, and the only claim this test supports is that the kind
        // guard fires first. It cannot show that :317 is the guard that rejected, since
        // every guard in the branch throws the same error.
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_evfkm"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-evfkm1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-evfkm2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedARaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedA = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: acceptedARaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let (otherRevMap, otherRevHash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let c1Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: acceptedA.checkpointHash, eventSeq: 1, eventHead: otherRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [otherRevMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedARaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: c1Raw, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected event fork previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(prev.projection.checkpointBytes == acceptedARaw)
        #expect(prev.projection.conflictingCheckpointBytes == c1Raw)
        #expect(prev.projection.floorSecs == issuedAt + 10)
        // Candidate is a real CheckpointFork over the SAME accepted raw: the conflicting
        // sits at the accepted's own sequence and chains to the accepted's predecessor,
        // which is what makes it kind2 rather than kind3.
        let sameSeqConflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 2, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedARaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: sameSeqConflictingRaw, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindCheckpointFork)
        #expect(control.projection.checkpointBytes == acceptedARaw)
        #expect(control.projection.conflictingCheckpointBytes == sameSeqConflictingRaw)
        #expect(control.projection.floorSecs == issuedAt + 10)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func terminalEventForkConflictingChangedRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_evfcc"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-evfcc1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-evfcc2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedARaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let acceptedA = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: acceptedARaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        // Two alternative divergent events over the same accepted: same target and same
        // sequence, differing only in revoked_at, which is part of the revocation's
        // signed key set and therefore yields a different event hash and a different
        // divergent head. reason would serve equally well but is not a parameter of the
        // existing helper, and helpers are out of scope for this slice.
        let (altRev1Map, altRev1Hash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let (altRev2Map, altRev2Hash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt + 1, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        #expect(altRev2Hash != altRev1Hash)
        let c1Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: acceptedA.checkpointHash, eventSeq: 1, eventHead: altRev1Hash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [altRev1Map], pCert: oCert)
        let c2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: acceptedA.checkpointHash, eventSeq: 1, eventHead: altRev2Hash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [altRev2Map], pCert: oCert)
        #expect(c2Raw != c1Raw)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedARaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: c1Raw, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected event fork previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(prev.projection.checkpointBytes == acceptedARaw)
        #expect(prev.projection.conflictingCheckpointBytes == c1Raw)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedARaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: c2Raw, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(control.projection.checkpointBytes == acceptedARaw)
        #expect(control.projection.conflictingCheckpointBytes == c2Raw)
        #expect(control.projection.floorSecs == issuedAt + 10)
        // Accepted raw is byte-identical on both sides and the kind ties, so :317 and
        // :319 both pass and the conflicting byte guard is the only one left to reject.
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    // MARK: - Genesis pin (basis substitution)

    // These three cover what the byte and identity guards cannot see: a candidate whose
    // whole chain is internally valid but rederives against a DIFFERENT genesis. Without
    // the genesis pin N1 and N2 would be accepted outright, because advancing the
    // sequence skips the same-sequence byte guard, and N3 would be accepted even with
    // both raws byte-identical, because an accepted checkpoint at sequence 3 rederives
    // against whatever genesis the snapshot carries.

    @Test func substitutedGenesisSameShapeRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_gpsub"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-gpsub1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-gpsub2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.checkpointSequence == 2)
        #expect(prev.projection.genesisCheckpointHash == genesis.checkpointHash)
        // Rival genesis: same household, same epoch, same owner cert, same members, only
        // the mesh digest differs. The revocation is reusable because a revocation never
        // references the genesis hash, so the rival chain reaches the same event head.
        let rivalGenesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xEE, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let rivalGenesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: rivalGenesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        #expect(rivalGenesis.checkpointHash != genesis.checkpointHash)
        let rivalSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: rivalGenesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xEE, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let rivalSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: rivalSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let rivalSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: rivalSeq2.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xEE, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: rivalGenesisRaw, acceptedCheckpoint: rivalSeq3Raw, predecessorCheckpoint: rivalSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 1)
        #expect(control.projection.epoch == prev.projection.epoch)
        #expect(control.projection.ownerCertFingerprint == prev.projection.ownerCertFingerprint)
        #expect(control.projection.genesisCheckpointHash == rivalGenesis.checkpointHash)
        #expect(control.projection.genesisCheckpointHash != prev.projection.genesisCheckpointHash)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func substitutedGenesisWidensMembershipRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_gpwid"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        // Third machine, test-local: the substituted basis smuggles it in as a member.
        let m3Key = try P256.Signing.PrivateKey(rawRepresentation: Data((161...192).map(UInt8.init)))
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-gpwid1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-gpwid2", issuedAt: issuedAt)
        let (m3Cert, m3Id, m3Pub, m3Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m3Key, hostname: "mac-gpwid3", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let m3Entry = memberMap(mId: m3Id, mPub: m3Pub, machineCert: m3Cert, fingerprint: m3Fp)
        func sortEntries(_ entries: [[String: HouseholdCBORValue]]) -> [[String: HouseholdCBORValue]] {
            entries.sorted { a, b in
                guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
                return aId < bId
            }
        }
        let genesisActive = sortEntries([m1Entry, m2Entry])
        let widenedActive = sortEntries([m1Entry, m2Entry, m3Entry])
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.member(for: m3Id) == nil)
        #expect(prev.projection.genesisCheckpointHash == genesis.checkpointHash)
        let widenedGenesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: widenedActive, revocations: [], pCert: oCert)
        let widenedGenesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: widenedGenesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let widenedSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: widenedGenesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m3Entry]), revocations: [revMap], pCert: oCert)
        let widenedSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: widenedSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let widenedSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: widenedSeq2.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m3Entry]), revocations: [revMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: widenedGenesisRaw, acceptedCheckpoint: widenedSeq3Raw, predecessorCheckpoint: widenedSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.epoch == prev.projection.epoch)
        #expect(control.projection.ownerCertFingerprint == prev.projection.ownerCertFingerprint)
        // The control proves the impact the pin has to stop: on the substituted basis the
        // third machine is a full active member of the roster the phone would trust.
        #expect(control.projection.member(for: m3Id) != nil)
        #expect(control.projection.member(for: m3Id)?.certFingerprint == m3Fp)
        #expect(control.projection.activeMembers.count == 2)
        #expect(control.projection.genesisCheckpointHash == widenedGenesis.checkpointHash)
        #expect(control.projection.genesisCheckpointHash != prev.projection.genesisCheckpointHash)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func terminalForkSubstitutedGenesisRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_gpfrk"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-gpfrk1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-gpfrk2", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let genesisActive = [m1Entry, m2Entry].sorted { a, b in
            guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
            return aId < bId
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revMap, revHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let predecessorRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let predecessor = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: predecessorRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: predecessor.checkpointHash, eventSeq: 1, eventHead: revHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revMap], pCert: oCert)
        let accepted = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: acceptedRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 20)
        let (altRevMap, altRevHash) = try makeRevocation(owner: owner, mId: m1Id, mPub: m1Pub, mCertFingerprint: m1Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let conflictingRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 4, prevHash: accepted.checkpointHash, eventSeq: 1, eventHead: altRevHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 30, notAfter: notAfter + 30, pId: pId, pCertFingerprint: oFp, active: [m2Entry], revocations: [altRevMap], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: predecessorRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected event fork previous"); return }
        #expect(prev.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(prev.projection.checkpointSequence == 3)
        #expect(prev.projection.genesisCheckpointHash == genesis.checkpointHash)
        // The accepted sits at sequence 3, so the snapshot reaches it through the
        // predecessor and never re-checks that the predecessor chains to THIS genesis.
        // That is what lets the basis be swapped with both raws left byte-identical.
        let rivalGenesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: genesisActive, revocations: [], pCert: oCert)
        let rivalGenesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: rivalGenesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        #expect(rivalGenesis.checkpointHash != genesis.checkpointHash)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 3, genesisCheckpoint: rivalGenesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: predecessorRaw, conflictingCheckpoint: conflictingRaw, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindEventFork)
        #expect(control.projection.checkpointBytes == prev.projection.checkpointBytes)
        #expect(control.projection.conflictingCheckpointBytes == prev.projection.conflictingCheckpointBytes)
        #expect(control.projection.genesisCheckpointHash == rivalGenesis.checkpointHash)
        #expect(control.projection.genesisCheckpointHash != prev.projection.genesisCheckpointHash)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    // MARK: - Event continuity (prefix boundary)

    // The genesis pin fixes the basis and the sequence guards fix how far the log has
    // advanced, but neither says WHICH events were applied. These three share one genesis
    // and one epoch and owner, so the only thing that can diverge is the event history:
    // a different event at the same position, the same events in another order, or a
    // genuine extension. Only the last one is a legal transition.

    @Test func eventHistoryDivergesAtBoundaryRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_ecdiv"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let m3Key = try P256.Signing.PrivateKey(rawRepresentation: Data((161...192).map(UInt8.init)))
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-ecdiv1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-ecdiv2", issuedAt: issuedAt)
        let (m3Cert, m3Id, m3Pub, m3Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m3Key, hostname: "mac-ecdiv3", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let m3Entry = memberMap(mId: m3Id, mPub: m3Pub, machineCert: m3Cert, fingerprint: m3Fp)
        func sortEntries(_ entries: [[String: HouseholdCBORValue]]) -> [[String: HouseholdCBORValue]] {
            entries.sorted { a, b in
                guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
                return aId < bId
            }
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry, m3Entry]), revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revM2Map, revM2Hash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revM2Hash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m3Entry]), revocations: [revM2Map], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.tombstones == [m2Id])
        #expect(prev.projection.eventHashes == [revM2Hash])
        #expect(prev.projection.eventHeadHash == revM2Hash)
        // Candidate revokes m3 instead of m2 at the very same position, then advances. Same
        // genesis, same epoch, same owner, non-regressing sequences: only the event at the
        // boundary differs, which is exactly what the sequence guards cannot see.
        let (revM3Map, revM3Hash) = try makeRevocation(owner: owner, mId: m3Id, mPub: m3Pub, mCertFingerprint: m3Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        #expect(revM3Hash != revM2Hash)
        let cSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revM3Hash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry]), revocations: [revM3Map], pCert: oCert)
        let cSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let cSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: cSeq2.checkpointHash, eventSeq: 1, eventHead: revM3Hash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry]), revocations: [revM3Map], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: cSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 1)
        #expect(control.projection.tombstones == [m3Id])
        #expect(control.projection.member(for: m1Id) != nil)
        #expect(control.projection.member(for: m2Id) != nil)
        #expect(control.projection.eventHashes == [revM3Hash])
        #expect(control.projection.eventHeadHash != prev.projection.eventHeadHash)
        #expect(control.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        #expect(control.projection.epoch == prev.projection.epoch)
        #expect(control.projection.ownerCertFingerprint == prev.projection.ownerCertFingerprint)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func eventHistoryReorderedRejected() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_ecord"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let m3Key = try P256.Signing.PrivateKey(rawRepresentation: Data((161...192).map(UInt8.init)))
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-ecord1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-ecord2", issuedAt: issuedAt)
        let (m3Cert, m3Id, m3Pub, m3Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m3Key, hostname: "mac-ecord3", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let m3Entry = memberMap(mId: m3Id, mPub: m3Pub, machineCert: m3Cert, fingerprint: m3Fp)
        func sortEntries(_ entries: [[String: HouseholdCBORValue]]) -> [[String: HouseholdCBORValue]] {
            entries.sorted { a, b in
                guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
                return aId < bId
            }
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry, m3Entry]), revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revM2Map, revM2Hash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revM2Hash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m3Entry]), revocations: [revM2Map], pCert: oCert)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.eventHashes == [revM2Hash])
        // Candidate applies BOTH revocations, so it ends at the same membership the phone
        // would eventually reach, and its event sequence is strictly ahead. But it applied
        // them in the other order, so the prefix the phone already accepted is not a
        // prefix of this history at all.
        let (revM3FirstMap, revM3FirstHash) = try makeRevocation(owner: owner, mId: m3Id, mPub: m3Pub, mCertFingerprint: m3Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let (revM2SecondMap, revM2SecondHash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 2, prevEventHash: revM3FirstHash, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let cSeq2Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revM3FirstHash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry]), revocations: [revM3FirstMap], pCert: oCert)
        let cSeq2 = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: cSeq2Raw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let cSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: cSeq2.checkpointHash, eventSeq: 2, eventHead: revM2SecondHash, meshDigest: Data(repeating: 0xDD, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revM3FirstMap, revM2SecondMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: cSeq2Raw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let controlOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let control) = controlOutcome else { Issue.record("expected available control"); return }
        #expect(control.projection.checkpointSequence == 3)
        #expect(control.projection.eventSequence == 2)
        #expect(control.projection.tombstones == [m3Id, m2Id])
        #expect(control.projection.activeMembers.map(\.mId) == [m1Id])
        #expect(control.projection.eventHashes == [revM3FirstHash, revM2SecondHash])
        #expect(control.projection.eventHashes[0] != prev.projection.eventHeadHash)
        #expect(control.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        #expect(throws: RosterEvidenceError.transitionInvalid) {
            try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        }
    }

    @Test func eventHistoryExtendedBeyondBoundaryAccepted() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let hhId = "hh_ecext"
        let epoch = Data(repeating: 0xBB, count: 32)
        let issuedAt: UInt64 = 1000; let notAfter: UInt64 = issuedAt + 250
        let (oCert, pId, oFp) = try makeOwnerCert(root: root, owner: owner, hhId: hhId, issuedAt: issuedAt)
        let m1Key = try machine1Key(); let m2Key = try machine2Key()
        let m3Key = try P256.Signing.PrivateKey(rawRepresentation: Data((161...192).map(UInt8.init)))
        let (m1Cert, m1Id, m1Pub, m1Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m1Key, hostname: "mac-ecext1", issuedAt: issuedAt)
        let (m2Cert, m2Id, m2Pub, m2Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m2Key, hostname: "mac-ecext2", issuedAt: issuedAt)
        let (m3Cert, m3Id, m3Pub, m3Fp) = try machineCert(root: root, hhId: hhId, machinePriv: m3Key, hostname: "mac-ecext3", issuedAt: issuedAt)
        let m1Entry = memberMap(mId: m1Id, mPub: m1Pub, machineCert: m1Cert, fingerprint: m1Fp)
        let m2Entry = memberMap(mId: m2Id, mPub: m2Pub, machineCert: m2Cert, fingerprint: m2Fp)
        let m3Entry = memberMap(mId: m3Id, mPub: m3Pub, machineCert: m3Cert, fingerprint: m3Fp)
        func sortEntries(_ entries: [[String: HouseholdCBORValue]]) -> [[String: HouseholdCBORValue]] {
            entries.sorted { a, b in
                guard case .text(let aId) = a["m_id"], case .text(let bId) = b["m_id"] else { return false }
                return aId < bId
            }
        }
        let genesisRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 1, prevHash: Data(repeating: 0, count: 32), eventSeq: 0, eventHead: Data(repeating: 0, count: 32), meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt, notAfter: notAfter, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m2Entry, m3Entry]), revocations: [], pCert: oCert)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: genesisRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt)
        let (revM2Map, revM2Hash) = try makeRevocation(owner: owner, mId: m2Id, mPub: m2Pub, mCertFingerprint: m2Fp, hhId: hhId, epoch: epoch, sequence: 1, prevEventHash: RosterAuthorityVerifier.zeroHash32, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let acceptedRaw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 2, prevHash: genesis.checkpointHash, eventSeq: 1, eventHead: revM2Hash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 10, notAfter: notAfter + 10, pId: pId, pCertFingerprint: oFp, active: sortEntries([m1Entry, m3Entry]), revocations: [revM2Map], pCert: oCert)
        let accepted = try RosterAuthorityVerifier.verifyCheckpointRecord(canonicalCheckpoint: acceptedRaw, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt + 10)
        let prevSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: acceptedRaw, predecessorCheckpoint: genesisRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let prevResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: prevSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: prevSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: prevSnap))
        let prevOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: prevResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: m1Fp), previousProjection: nil)
        guard case .available(let prev) = prevOutcome else { Issue.record("expected accepted previous"); return }
        #expect(prev.projection.eventHashes == [revM2Hash])
        #expect(prev.projection.eventHeadHash == revM2Hash)
        // The legal move: keep the accepted history as a true prefix and append one new
        // event on top of it. The boundary head still matches, so this must be accepted.
        let (revM3NextMap, revM3NextHash) = try makeRevocation(owner: owner, mId: m3Id, mPub: m3Pub, mCertFingerprint: m3Fp, hhId: hhId, epoch: epoch, sequence: 2, prevEventHash: revM2Hash, revokedAt: issuedAt, pId: pId, pCertFingerprint: oFp, pCert: oCert)
        let cSeq3Raw = try makeCheckpoint(owner: owner, hhId: hhId, epoch: epoch, seq: 3, prevHash: accepted.checkpointHash, eventSeq: 2, eventHead: revM3NextHash, meshDigest: Data(repeating: 0xCC, count: 32), issuedAt: issuedAt + 20, notAfter: notAfter + 20, pId: pId, pCertFingerprint: oFp, active: [m1Entry], revocations: [revM2Map, revM3NextMap], pCert: oCert)
        let candidateSnap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: genesisRaw, acceptedCheckpoint: cSeq3Raw, predecessorCheckpoint: acceptedRaw, conflictingCheckpoint: nil, floorSecs: issuedAt + 10)
        let candidateResponse = try evidenceResponse(machinePriv: m1Key, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp, nonce: testNonce, outcome: "available", snapshotBody: candidateSnap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: candidateSnap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: candidateSnap))
        let stable = try RosterSignerBinding(hhId: hhId, mId: m1Id, machineCert: m1Cert, machineCertFingerprint: m1Fp)
        let advanceOutcome = try RosterEvidenceVerifier.verifyEvidenceResponse(response: candidateResponse, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .stableBinding(stable), previousProjection: prev.projection)
        guard case .available(let advanced) = advanceOutcome else { Issue.record("expected available extension"); return }
        #expect(advanced.projection.stateKind == VerifiedRosterProjection.stateKindAccepted)
        #expect(advanced.projection.checkpointSequence == 3)
        #expect(advanced.projection.eventSequence == 2)
        #expect(advanced.projection.tombstones == [m2Id, m3Id])
        #expect(advanced.projection.activeMembers.map(\.mId) == [m1Id])
        #expect(advanced.projection.eventHashes == [revM2Hash, revM3NextHash])
        #expect(advanced.projection.eventHashes[0] == prev.projection.eventHeadHash)
        #expect(advanced.projection.eventHeadHash == revM3NextHash)
        #expect(advanced.projection.genesisCheckpointHash == prev.projection.genesisCheckpointHash)
        #expect(advanced.projection.checkpointBytes == cSeq3Raw)
    }

    // MARK: - Digest mismatches

    @Test func digestMismatchStateEvidence() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_digse"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-digse", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let correctSnap = computeFullSnapshotDigest(snapshot: snap)
        let wrong = Data(repeating: 0xEE, count: 32)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: wrong, fullSnapshotDigest: correctSnap)
        #expect(throws: RosterEvidenceError.digestMismatch) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func digestMismatchFullSnapshot() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_digfs"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-digfs", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let correctEv = computeStateEvidenceDigest(snapshot: snap)
        let wrong = Data(repeating: 0xEE, count: 32)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: correctEv, fullSnapshotDigest: wrong)
        #expect(throws: RosterEvidenceError.digestMismatch) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    // MARK: - Remaining error cases

    @Test func snapshotKeySetInvalid() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_ksinv"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-ksinv", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 1, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let ev = computeStateEvidenceDigest(snapshot: snap); let sn = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: ev, fullSnapshotDigest: sn)
        #expect(throws: RosterEvidenceError.snapshotKeySetInvalid) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func unavailableWithSnapshotBodyFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_unavsb"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-unavsb", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let ev = computeStateEvidenceDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "unavailable_clock_state", snapshotBody: snap, stateEvidenceDigest: ev, fullSnapshotDigest: nil)
        #expect(throws: RosterEvidenceError.unavailableNeverPersists) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func evidenceBadOutcomeString() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_badout"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-badout", issuedAt: issuedAt)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "bogus", snapshotBody: nil, stateEvidenceDigest: nil, fullSnapshotDigest: nil)
        #expect(throws: RosterEvidenceError.certBindingInvalid) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func evidenceNonceMismatch() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_evnm"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-evnm", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let ev = computeStateEvidenceDigest(snapshot: snap); let sn = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: ev, fullSnapshotDigest: sn)
        #expect(throws: RosterEvidenceError.nonceMismatch) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: Data(repeating: 0xCC, count: 32), expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func evidenceQRWithPreviousProjectionFails() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_qrprev"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-qrprev", issuedAt: issuedAt)
        let prev = try VerifiedRosterProjection(stateKind: VerifiedRosterProjection.stateKindNoGenesis, hhId: hhId, epoch: nil, checkpointSequence: nil, eventSequence: nil, issuedAt: nil, notAfter: nil, floorSecs: issuedAt, activeMembers: [], tombstones: [], checkpointBytes: nil, ownerCertFingerprint: nil, genesisCheckpointHash: nil, eventHashes: [], conflictingCheckpointBytes: nil)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.anchorMismatch) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: prev) }
    }

    @Test func evidenceSignatureInvalid() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_evsig"; let issuedAt: UInt64 = 1000
        let mKey = try machine1Key(); let wrongKey = try machine2Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-evsig", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: hhId, stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let response = try evidenceResponse(machinePriv: wrongKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: computeStateEvidenceDigest(snapshot: snap), fullSnapshotDigest: computeFullSnapshotDigest(snapshot: snap))
        #expect(throws: RosterEvidenceError.signatureInvalid) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }

    @Test func snapshotHHIdMismatch() throws {
        let root = try rootKey(); let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_shhm"; let issuedAt: UInt64 = 1000; let mKey = try machine1Key()
        let (mCert, mId, _, mFp) = try machineCert(root: root, hhId: hhId, machinePriv: mKey, hostname: "mac-shhm", issuedAt: issuedAt)
        let snap = RosterEvidenceSnapshotBody(v: 1, hhId: "wrong_hh", stateKind: 0, genesisCheckpoint: nil, acceptedCheckpoint: nil, predecessorCheckpoint: nil, conflictingCheckpoint: nil, floorSecs: issuedAt)
        let ev = computeStateEvidenceDigest(snapshot: snap); let sn = computeFullSnapshotDigest(snapshot: snap)
        let response = try evidenceResponse(machinePriv: mKey, mId: mId, machineCert: mCert, machineCertFingerprint: mFp, nonce: testNonce, outcome: "available", snapshotBody: snap, stateEvidenceDigest: ev, fullSnapshotDigest: sn)
        #expect(throws: RosterEvidenceError.certBindingInvalid) { try RosterEvidenceVerifier.verifyEvidenceResponse(response: response, expectedNonce: testNonce, expectedHouseholdId: hhId, householdPublicKey: rootPub, anchor: .qrPin(fingerprint: mFp), previousProjection: nil) }
    }
}
