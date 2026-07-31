import CryptoKit
import Foundation

public enum RosterEvidenceError: Error, Equatable, Sendable {
    case nonceMismatch
    case certBindingInvalid
    case fingerprintMismatch
    case signatureInvalid
    case snapshotKeySetInvalid
    case digestMismatch
    case transitionInvalid
    case unavailableNeverPersists
    case anchorMismatch
}

public enum RosterEvidenceAnchor: Equatable, Sendable {
    case qrPin(fingerprint: Data)
    case stableBinding(RosterSignerBinding)
}

public struct RosterAvailableEvidence: Equatable, Sendable {
    public let projection: VerifiedRosterProjection
    public let signerBinding: RosterSignerBinding
    public let canonicalSnapshotBody: Data
    public let stateEvidenceDigest: Data
    public let fullSnapshotDigest: Data
}

public enum RosterEvidenceOutcome: Equatable, Sendable {
    case unavailable(binding: RosterSignerBinding, outcome: String)
    case available(RosterAvailableEvidence)
}

public enum RosterEvidenceVerifier {
    static let evidenceDomain = Data("soyeht/roster-evidence/v1\u{0}".utf8)
    static let snapshotDomain = Data("soyeht/roster-snapshot/v1\u{0}".utf8)
    static let signerPinDomain = Data("soyeht/roster-signer-pin/v1\u{0}".utf8)

    static let evidenceOutcomes: Set<String> = [
        "available",
        "unavailable_clock_state",
        "unavailable_owner_authority",
        "unavailable_checkpoint_stale",
    ]

    public static func verifySignerPinResponse(
        response: RosterSignerPinResponse,
        expectedNonce: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        anchorFingerprint: Data
    ) throws -> RosterSignerBinding {
        guard response.v == 1 else { throw RosterEvidenceError.certBindingInvalid }
        guard response.clientNonce.count == 32, response.clientNonce == expectedNonce else {
            throw RosterEvidenceError.nonceMismatch
        }
        guard response.hhId == expectedHouseholdId else {
            throw RosterEvidenceError.certBindingInvalid
        }
        guard response.machineCertFingerprint == anchorFingerprint else {
            throw RosterEvidenceError.anchorMismatch
        }
        let binding = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
            certCBOR: response.machineCert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        guard binding.mId == response.mId else {
            throw RosterEvidenceError.certBindingInvalid
        }
        guard binding.fingerprint == response.machineCertFingerprint else {
            throw RosterEvidenceError.fingerprintMismatch
        }
        let unsigned: [String: HouseholdCBORValue] = [
            "hh_id": .text(response.hhId),
            "m_id": .text(response.mId),
            "machine_cert": .bytes(response.machineCert),
            "machine_cert_fingerprint": .bytes(response.machineCertFingerprint),
            "client_nonce": .bytes(response.clientNonce),
            "v": .unsigned(1),
        ]
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        var preimage = Data()
        preimage.append(signerPinDomain)
        preimage.append(canonicalUnsigned)
        guard response.signature.count == 64 else { throw RosterEvidenceError.signatureInvalid }
        try verifyMachineSignature(
            signature: response.signature,
            message: preimage,
            machinePublicKey: binding.mPub
        )
        return try RosterSignerBinding(
            hhId: response.hhId,
            mId: binding.mId,
            machineCert: response.machineCert,
            machineCertFingerprint: binding.fingerprint
        )
    }

    public static func verifyEvidenceResponse(
        response: RosterEvidenceResponse,
        expectedNonce: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        anchor: RosterEvidenceAnchor,
        previousProjection: VerifiedRosterProjection?
    ) throws -> RosterEvidenceOutcome {
        guard response.v == 1 else { throw RosterEvidenceError.certBindingInvalid }
        guard evidenceOutcomes.contains(response.outcome) else { throw RosterEvidenceError.certBindingInvalid }
        guard response.clientNonce.count == 32, response.clientNonce == expectedNonce else {
            throw RosterEvidenceError.nonceMismatch
        }
        let binding = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
            certCBOR: response.signerMachineCert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        guard binding.mId == response.signerMId else {
            throw RosterEvidenceError.certBindingInvalid
        }
        guard binding.fingerprint == response.signerMachineCertFingerprint else {
            throw RosterEvidenceError.fingerprintMismatch
        }
        switch anchor {
        case .qrPin(let fingerprint):
            guard response.signerMachineCertFingerprint == fingerprint else {
                throw RosterEvidenceError.anchorMismatch
            }
        case .stableBinding(let stable):
            guard stable.v == 1,
                  stable.hhId == expectedHouseholdId,
                  response.signerMId == stable.mId,
                  response.signerMachineCert == stable.machineCert,
                  response.signerMachineCertFingerprint == stable.machineCertFingerprint else {
                throw RosterEvidenceError.anchorMismatch
            }
        }
        guard response.signature.count == 64 else { throw RosterEvidenceError.signatureInvalid }

        let signerBinding = try RosterSignerBinding(
            hhId: expectedHouseholdId,
            mId: binding.mId,
            machineCert: response.signerMachineCert,
            machineCertFingerprint: binding.fingerprint
        )

        if response.outcome == "available" {
            guard let snapshot = response.snapshotBody,
                  let evDigest = response.stateEvidenceDigest,
                  let snapDigest = response.fullSnapshotDigest else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
            guard snapshot.hhId == expectedHouseholdId else {
                throw RosterEvidenceError.certBindingInvalid
            }
            try validateSnapshotMatrix(snapshot)
            let stateEvidenceMap = snapshotBodyMap(snapshot, includeFloor: false)
            var evidencePreimage = Data()
            evidencePreimage.append(evidenceDomain)
            evidencePreimage.append(HouseholdCBOR.encode(.map(stateEvidenceMap)))
            guard Data(SHA256.hash(data: evidencePreimage)) == evDigest else {
                throw RosterEvidenceError.digestMismatch
            }
            let fullSnapshotMap = snapshotBodyMap(snapshot, includeFloor: true)
            let canonicalSnapshotBody = HouseholdCBOR.encode(.map(fullSnapshotMap))
            var snapshotPreimage = Data()
            snapshotPreimage.append(snapshotDomain)
            snapshotPreimage.append(canonicalSnapshotBody)
            guard Data(SHA256.hash(data: snapshotPreimage)) == snapDigest else {
                throw RosterEvidenceError.digestMismatch
            }
            try verifyEvidenceSignature(
                response: response,
                snapshotBody: snapshot,
                stateEvidenceDigest: evDigest,
                fullSnapshotDigest: snapDigest,
                machinePublicKey: binding.mPub
            )
            let projection = try buildProjection(
                snapshot: snapshot,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey
            )
            try verifySignerMembershipAnchor(
                anchor: anchor,
                previousProjection: previousProjection,
                candidateProjection: projection,
                signerBinding: signerBinding,
                signerMachinePublicKey: binding.mPub
            )
            try validateAvailableTransition(previous: previousProjection, candidate: projection)
            return .available(RosterAvailableEvidence(
                projection: projection,
                signerBinding: signerBinding,
                canonicalSnapshotBody: canonicalSnapshotBody,
                stateEvidenceDigest: evDigest,
                fullSnapshotDigest: snapDigest
            ))
        } else {
            guard response.snapshotBody == nil,
                  response.stateEvidenceDigest == nil,
                  response.fullSnapshotDigest == nil else {
                throw RosterEvidenceError.unavailableNeverPersists
            }
            try verifyEvidenceSignature(
                response: response,
                snapshotBody: nil,
                stateEvidenceDigest: nil,
                fullSnapshotDigest: nil,
                machinePublicKey: binding.mPub
            )
            try verifySignerMembershipAnchor(
                anchor: anchor,
                previousProjection: previousProjection,
                candidateProjection: nil,
                signerBinding: signerBinding,
                signerMachinePublicKey: binding.mPub
            )
            return .unavailable(binding: signerBinding, outcome: response.outcome)
        }
    }

    private static func verifySignerMembershipAnchor(
        anchor: RosterEvidenceAnchor,
        previousProjection: VerifiedRosterProjection?,
        candidateProjection: VerifiedRosterProjection?,
        signerBinding: RosterSignerBinding,
        signerMachinePublicKey: Data
    ) throws {
        switch anchor {
        case .qrPin:
            guard previousProjection == nil else { throw RosterEvidenceError.anchorMismatch }
            if let candidate = candidateProjection,
               candidate.stateKind != VerifiedRosterProjection.stateKindNoGenesis {
                try requireSignerActiveMember(
                    projection: candidate,
                    binding: signerBinding,
                    signerMachinePublicKey: signerMachinePublicKey
                )
            }
        case .stableBinding:
            guard let previous = previousProjection else { throw RosterEvidenceError.anchorMismatch }
            guard previous.hhId == signerBinding.hhId else { throw RosterEvidenceError.anchorMismatch }
            if previous.stateKind == VerifiedRosterProjection.stateKindNoGenesis {
                if let candidate = candidateProjection,
                   candidate.stateKind != VerifiedRosterProjection.stateKindNoGenesis {
                    try requireSignerActiveMember(
                        projection: candidate,
                        binding: signerBinding,
                        signerMachinePublicKey: signerMachinePublicKey
                    )
                }
            } else {
                try requireSignerActiveMember(
                    projection: previous,
                    binding: signerBinding,
                    signerMachinePublicKey: signerMachinePublicKey
                )
            }
        }
    }

    private static func requireSignerActiveMember(
        projection: VerifiedRosterProjection,
        binding: RosterSignerBinding,
        signerMachinePublicKey: Data
    ) throws {
        guard let member = projection.member(for: binding.mId) else {
            throw RosterEvidenceError.anchorMismatch
        }
        guard member.mId == binding.mId,
              member.mPub == signerMachinePublicKey,
              member.certBytes == binding.machineCert,
              member.certFingerprint == binding.machineCertFingerprint else {
            throw RosterEvidenceError.anchorMismatch
        }
    }

    private static func validateAvailableTransition(
        previous: VerifiedRosterProjection?,
        candidate: VerifiedRosterProjection
    ) throws {
        guard let previous = previous else { return }
        guard candidate.floorSecs >= previous.floorSecs else { throw RosterEvidenceError.transitionInvalid }
        switch previous.stateKind {
        case VerifiedRosterProjection.stateKindNoGenesis:
            guard candidate.hhId == previous.hhId else { throw RosterEvidenceError.transitionInvalid }
        case VerifiedRosterProjection.stateKindAccepted:
            guard candidate.stateKind != VerifiedRosterProjection.stateKindNoGenesis else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard candidate.hhId == previous.hhId else { throw RosterEvidenceError.transitionInvalid }
            guard candidate.epoch == previous.epoch else { throw RosterEvidenceError.transitionInvalid }
            guard candidate.ownerCertFingerprint == previous.ownerCertFingerprint else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard let candidateCheckpointSequence = candidate.checkpointSequence,
                  let previousCheckpointSequence = previous.checkpointSequence else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard candidateCheckpointSequence >= previousCheckpointSequence else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard let candidateEventSequence = candidate.eventSequence,
                  let previousEventSequence = previous.eventSequence else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard candidateEventSequence >= previousEventSequence else {
                throw RosterEvidenceError.transitionInvalid
            }
            // Event continuity: a non-regressing event sequence still allows the candidate
            // to have applied DIFFERENT events, or the same ones in another order. Replay
            // the previous head as a prefix boundary: whatever the candidate did beyond
            // that boundary is new history, but everything up to it must hash to the head
            // the phone already accepted.
            guard let eventBoundary = Int(exactly: previousEventSequence) else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard candidate.eventHashes.count >= eventBoundary else {
                throw RosterEvidenceError.transitionInvalid
            }
            let candidateBoundaryHead = eventBoundary == 0
                ? RosterAuthorityVerifier.zeroHash32
                : candidate.eventHashes[eventBoundary - 1]
            guard candidateBoundaryHead == previous.eventHeadHash else {
                throw RosterEvidenceError.transitionInvalid
            }
            if candidateCheckpointSequence == previousCheckpointSequence {
                guard candidate.checkpointBytes == previous.checkpointBytes else {
                    throw RosterEvidenceError.transitionInvalid
                }
            }
            // Deliberately last in this case: a substituted genesis also perturbs epoch,
            // owner and the accepted bytes, so checking it earlier would mask whichever
            // of those diverged and steal the causality of the guards above.
            guard candidate.genesisCheckpointHash == previous.genesisCheckpointHash else {
                throw RosterEvidenceError.transitionInvalid
            }
        case VerifiedRosterProjection.stateKindCheckpointFork, VerifiedRosterProjection.stateKindEventFork:
            guard candidate.stateKind == previous.stateKind else { throw RosterEvidenceError.transitionInvalid }
            guard candidate.hhId == previous.hhId else { throw RosterEvidenceError.transitionInvalid }
            guard candidate.checkpointBytes == previous.checkpointBytes else {
                throw RosterEvidenceError.transitionInvalid
            }
            guard candidate.conflictingCheckpointBytes == previous.conflictingCheckpointBytes else {
                throw RosterEvidenceError.transitionInvalid
            }
            // Last in this case for the same reason, and load-bearing here in a way the
            // byte guards above are not: an accepted checkpoint at sequence 3 or higher
            // rederives against the basis of whatever genesis the snapshot carries, so
            // both raws can stay byte-identical while the basis underneath is swapped.
            guard candidate.genesisCheckpointHash == previous.genesisCheckpointHash else {
                throw RosterEvidenceError.transitionInvalid
            }
        default:
            throw RosterEvidenceError.transitionInvalid
        }
    }

    static func verifyEvidenceSignature(
        response: RosterEvidenceResponse,
        snapshotBody: RosterEvidenceSnapshotBody?,
        stateEvidenceDigest: Data?,
        fullSnapshotDigest: Data?,
        machinePublicKey: Data
    ) throws {
        var unsigned: [String: HouseholdCBORValue] = [
            "client_nonce": .bytes(response.clientNonce),
            "outcome": .text(response.outcome),
            "signer_m_id": .text(response.signerMId),
            "signer_machine_cert": .bytes(response.signerMachineCert),
            "signer_machine_cert_fingerprint": .bytes(response.signerMachineCertFingerprint),
            "v": .unsigned(1),
        ]
        if let snapshot = snapshotBody {
            unsigned["snapshot_body"] = .map(snapshotBodyMap(snapshot, includeFloor: true))
        }
        if let digest = stateEvidenceDigest { unsigned["state_evidence_digest"] = .bytes(digest) }
        if let digest = fullSnapshotDigest { unsigned["full_snapshot_digest"] = .bytes(digest) }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        var preimage = Data()
        preimage.append(evidenceDomain)
        preimage.append(canonicalUnsigned)
        try verifyMachineSignature(
            signature: response.signature,
            message: preimage,
            machinePublicKey: machinePublicKey
        )
    }

    private static func validateSnapshotMatrix(_ snapshot: RosterEvidenceSnapshotBody) throws {
        guard snapshot.v == 1 else { throw RosterEvidenceError.snapshotKeySetInvalid }
        guard snapshot.stateKind <= 3 else { throw RosterEvidenceError.snapshotKeySetInvalid }
        switch UInt8(snapshot.stateKind) {
        case VerifiedRosterProjection.stateKindNoGenesis:
            guard snapshot.genesisCheckpoint == nil,
                  snapshot.acceptedCheckpoint == nil,
                  snapshot.predecessorCheckpoint == nil,
                  snapshot.conflictingCheckpoint == nil else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
        case VerifiedRosterProjection.stateKindAccepted:
            guard let accepted = snapshot.acceptedCheckpoint,
                  snapshot.genesisCheckpoint != nil,
                  snapshot.conflictingCheckpoint == nil else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
            try validatePredecessorPresence(snapshot: snapshot, acceptedCheckpoint: accepted)
        case VerifiedRosterProjection.stateKindCheckpointFork, VerifiedRosterProjection.stateKindEventFork:
            guard let accepted = snapshot.acceptedCheckpoint,
                  snapshot.genesisCheckpoint != nil,
                  snapshot.conflictingCheckpoint != nil else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
            try validatePredecessorPresence(snapshot: snapshot, acceptedCheckpoint: accepted)
        default:
            throw RosterEvidenceError.snapshotKeySetInvalid
        }
    }

    private static func validatePredecessorPresence(
        snapshot: RosterEvidenceSnapshotBody,
        acceptedCheckpoint: Data
    ) throws {
        let acceptedSequence = try checkpointSequence(acceptedCheckpoint)
        if acceptedSequence > 1 {
            guard snapshot.predecessorCheckpoint != nil else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
        } else {
            guard snapshot.predecessorCheckpoint == nil else {
                throw RosterEvidenceError.snapshotKeySetInvalid
            }
        }
    }

    private static func checkpointSequence(_ checkpointBytes: Data) throws -> UInt64 {
        let decoded = try RosterWire.decodeCanonical(checkpointBytes)
        guard case .map(let map) = decoded else {
            throw RosterEvidenceError.snapshotKeySetInvalid
        }
        return try RosterWire.requireUInt(map, "checkpoint_sequence")
    }

    private static func snapshotBodyMap(
        _ snapshot: RosterEvidenceSnapshotBody,
        includeFloor: Bool
    ) -> [String: HouseholdCBORValue] {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(snapshot.v),
            "hh_id": .text(snapshot.hhId),
            "state_kind": .unsigned(snapshot.stateKind),
        ]
        if includeFloor {
            map["floor_secs"] = .unsigned(snapshot.floorSecs)
        }
        if let genesis = snapshot.genesisCheckpoint { map["genesis_checkpoint"] = .bytes(genesis) }
        if let accepted = snapshot.acceptedCheckpoint { map["accepted_checkpoint"] = .bytes(accepted) }
        if let predecessor = snapshot.predecessorCheckpoint { map["predecessor_checkpoint"] = .bytes(predecessor) }
        if let conflicting = snapshot.conflictingCheckpoint { map["conflicting_checkpoint"] = .bytes(conflicting) }
        return map
    }

    static func verifyMachineSignature(
        signature: Data,
        message: Data,
        machinePublicKey: Data
    ) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: machinePublicKey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(sig, for: message) else {
                throw RosterEvidenceError.signatureInvalid
            }
        } catch let error as RosterEvidenceError {
            throw error
        } catch {
            throw RosterEvidenceError.signatureInvalid
        }
    }

    static func buildProjection(
        snapshot: RosterEvidenceSnapshotBody,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> VerifiedRosterProjection {
        guard snapshot.hhId == expectedHouseholdId else { throw RosterEvidenceError.certBindingInvalid }
        try validateSnapshotMatrix(snapshot)
        switch UInt8(snapshot.stateKind) {
        case VerifiedRosterProjection.stateKindNoGenesis:
            return try buildNoGenesisProjection(snapshot: snapshot)
        case VerifiedRosterProjection.stateKindAccepted:
            return try buildAcceptedProjection(
                snapshot: snapshot,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey
            )
        case VerifiedRosterProjection.stateKindCheckpointFork, VerifiedRosterProjection.stateKindEventFork:
            return try buildForkProjection(
                snapshot: snapshot,
                expectedHouseholdId: expectedHouseholdId,
                householdPublicKey: householdPublicKey
            )
        default:
            throw RosterEvidenceError.transitionInvalid
        }
    }

    private static func buildNoGenesisProjection(
        snapshot: RosterEvidenceSnapshotBody
    ) throws -> VerifiedRosterProjection {
        try VerifiedRosterProjection(
            stateKind: VerifiedRosterProjection.stateKindNoGenesis,
            hhId: snapshot.hhId,
            epoch: nil,
            checkpointSequence: nil,
            eventSequence: nil,
            issuedAt: nil,
            notAfter: nil,
            floorSecs: snapshot.floorSecs,
            activeMembers: [],
            tombstones: [],
            checkpointBytes: nil,
            ownerCertFingerprint: nil,
            genesisCheckpointHash: nil,
            eventHashes: [],
            conflictingCheckpointBytes: nil
        )
    }

    private static func rederiveAcceptedState(
        snapshot: RosterEvidenceSnapshotBody,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> (state: AcceptedRosterState, genesisCheckpointHash: Data) {
        guard let genesisBytes = snapshot.genesisCheckpoint,
              let acceptedBytes = snapshot.acceptedCheckpoint else {
            throw RosterEvidenceError.snapshotKeySetInvalid
        }
        let genesis = try verifyCheckpointAtOwnIssuedAt(
            genesisBytes,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let accepted = try verifyCheckpointAtOwnIssuedAt(
            acceptedBytes,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesis.issuedAt)
        if accepted.checkpointSequence == 1 {
            guard snapshot.predecessorCheckpoint == nil else { throw RosterEvidenceError.transitionInvalid }
            guard acceptedBytes == genesisBytes else { throw RosterEvidenceError.transitionInvalid }
            return (genesisState, genesis.checkpointHash)
        }
        guard let predecessorBytes = snapshot.predecessorCheckpoint else {
            throw RosterEvidenceError.transitionInvalid
        }
        let predecessor = try verifyCheckpointAtOwnIssuedAt(
            predecessorBytes,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let (expectedPredecessorSequence, underflow) = accepted.checkpointSequence.subtractingReportingOverflow(1)
        guard !underflow else { throw RosterEvidenceError.transitionInvalid }
        guard predecessor.checkpointSequence == expectedPredecessorSequence else {
            throw RosterEvidenceError.transitionInvalid
        }
        if predecessor.checkpointSequence == 1 {
            guard predecessorBytes == genesisBytes else { throw RosterEvidenceError.transitionInvalid }
            let outcome = try RosterAuthorityVerifier.advanceState(
                current: genesisState,
                candidate: accepted,
                effectiveNow: accepted.issuedAt
            )
            guard case .advanced(let next) = outcome else { throw RosterEvidenceError.transitionInvalid }
            return (next, genesis.checkpointHash)
        }
        guard predecessor.epoch == genesis.epoch else { throw RosterEvidenceError.transitionInvalid }
        guard predecessor.ownerCertFingerprint == genesis.ownerCertFingerprint else {
            throw RosterEvidenceError.transitionInvalid
        }
        let predecessorProjection = try RosterAuthorityVerifier.rederiveProjection(
            checkpoint: predecessor,
            basis: genesisState.basis,
            effectiveNow: predecessor.issuedAt
        )
        let bridge = AcceptedRosterState(
            checkpoint: predecessor,
            basis: genesisState.basis,
            projection: predecessorProjection,
            predecessorEventSequence: 0,
            predecessorEventHead: Data(repeating: 0, count: 32)
        )
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: bridge,
            candidate: accepted,
            effectiveNow: accepted.issuedAt
        )
        guard case .advanced(let next) = outcome else { throw RosterEvidenceError.transitionInvalid }
        return (next, genesis.checkpointHash)
    }

    private static func buildAcceptedProjection(
        snapshot: RosterEvidenceSnapshotBody,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> VerifiedRosterProjection {
        let rederived = try rederiveAcceptedState(
            snapshot: snapshot,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let acceptedState = rederived.state
        guard snapshot.floorSecs <= acceptedState.checkpoint.notAfter else {
            throw RosterEvidenceError.transitionInvalid
        }
        return try mapAcceptedProjection(
            snapshot: snapshot,
            acceptedState: acceptedState,
            stateKind: VerifiedRosterProjection.stateKindAccepted,
            genesisCheckpointHash: rederived.genesisCheckpointHash,
            conflictingCheckpointBytes: nil
        )
    }

    private static func buildForkProjection(
        snapshot: RosterEvidenceSnapshotBody,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> VerifiedRosterProjection {
        let rederived = try rederiveAcceptedState(
            snapshot: snapshot,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let acceptedState = rederived.state
        guard let conflictingBytes = snapshot.conflictingCheckpoint else {
            throw RosterEvidenceError.snapshotKeySetInvalid
        }
        let conflicting = try verifyCheckpointAtOwnIssuedAt(
            conflictingBytes,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(acceptedState),
            candidate: conflicting,
            effectiveNow: conflicting.issuedAt
        )
        let stateKind = UInt8(snapshot.stateKind)
        if stateKind == VerifiedRosterProjection.stateKindCheckpointFork {
            guard case .checkpointFork = outcome else { throw RosterEvidenceError.transitionInvalid }
        } else if stateKind == VerifiedRosterProjection.stateKindEventFork {
            guard case .eventFork = outcome else { throw RosterEvidenceError.transitionInvalid }
        } else {
            throw RosterEvidenceError.transitionInvalid
        }
        return try mapAcceptedProjection(
            snapshot: snapshot,
            acceptedState: acceptedState,
            stateKind: stateKind,
            genesisCheckpointHash: rederived.genesisCheckpointHash,
            conflictingCheckpointBytes: conflicting.rawCBOR
        )
    }

    private static func mapAcceptedProjection(
        snapshot: RosterEvidenceSnapshotBody,
        acceptedState: AcceptedRosterState,
        stateKind: UInt8,
        genesisCheckpointHash: Data,
        conflictingCheckpointBytes: Data?
    ) throws -> VerifiedRosterProjection {
        let activeMembers = try acceptedState.projection.active.map { member in
            try VerifiedMachineMember(
                mId: member.mId,
                mPub: member.mPub,
                certBytes: member.machineCert,
                certFingerprint: member.fingerprint
            )
        }
        let tombstones = acceptedState.projection.tombstones.map { $0.mId }
        // Same source and same order as the tombstones above, so the two lists stay
        // index-aligned by construction. No hash is computed here: each event hash was
        // already derived and checked while the revocation chain was verified.
        let eventHashes = acceptedState.projection.tombstones.map(\.eventHash)
        return try VerifiedRosterProjection(
            stateKind: stateKind,
            hhId: snapshot.hhId,
            epoch: acceptedState.checkpoint.epoch,
            checkpointSequence: acceptedState.checkpoint.checkpointSequence,
            eventSequence: acceptedState.checkpoint.eventSequence,
            issuedAt: acceptedState.checkpoint.issuedAt,
            notAfter: acceptedState.checkpoint.notAfter,
            floorSecs: snapshot.floorSecs,
            activeMembers: activeMembers,
            tombstones: tombstones,
            checkpointBytes: acceptedState.checkpoint.rawCBOR,
            ownerCertFingerprint: acceptedState.checkpoint.ownerCertFingerprint,
            genesisCheckpointHash: genesisCheckpointHash,
            eventHashes: eventHashes,
            conflictingCheckpointBytes: conflictingCheckpointBytes
        )
    }

    private static func verifyCheckpointAtOwnIssuedAt(
        _ checkpointBytes: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> VerifiedCheckpoint {
        let issuedAt = try peekIssuedAt(checkpointBytes)
        return try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: checkpointBytes,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey,
            effectiveNow: issuedAt
        )
    }

    private static func peekIssuedAt(_ checkpointBytes: Data) throws -> UInt64 {
        let decoded = try RosterWire.decodeCanonical(checkpointBytes)
        guard case .map(let map) = decoded else {
            throw RosterEvidenceError.snapshotKeySetInvalid
        }
        return try RosterWire.requireUInt(map, "issued_at")
    }
}
