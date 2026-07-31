import Foundation

public struct VerifiedMachineMember: Sendable, Equatable {
    public let mId: String
    public let mPub: Data
    public let certBytes: Data
    public let certFingerprint: Data

    init(mId: String, mPub: Data, certBytes: Data, certFingerprint: Data) throws {
        guard !mId.isEmpty, mPub.count == 33, !certBytes.isEmpty, certFingerprint.count == 32 else {
            throw RosterWireError.unexpectedKeySet
        }
        self.mId = mId
        self.mPub = mPub
        self.certBytes = certBytes
        self.certFingerprint = certFingerprint
    }
}

public struct VerifiedRosterProjection: Sendable, Equatable {
    public let stateKind: UInt8
    public let hhId: String
    public let epoch: Data?
    public let checkpointSequence: UInt64?
    public let eventSequence: UInt64?
    public let issuedAt: UInt64?
    public let notAfter: UInt64?
    public let floorSecs: UInt64
    public let activeMembers: [VerifiedMachineMember]
    public let tombstones: [String]
    public let checkpointBytes: Data?
    public let ownerCertFingerprint: Data?
    public let genesisCheckpointHash: Data?
    public let eventHashes: [Data]
    public let conflictingCheckpointBytes: Data?

    init(
        stateKind: UInt8,
        hhId: String,
        epoch: Data?,
        checkpointSequence: UInt64?,
        eventSequence: UInt64?,
        issuedAt: UInt64?,
        notAfter: UInt64?,
        floorSecs: UInt64,
        activeMembers: [VerifiedMachineMember],
        tombstones: [String],
        checkpointBytes: Data?,
        ownerCertFingerprint: Data?,
        genesisCheckpointHash: Data?,
        eventHashes: [Data],
        conflictingCheckpointBytes: Data?
    ) throws {
        guard stateKind <= 3, !hhId.isEmpty else {
            throw RosterWireError.unexpectedKeySet
        }
        if let e = epoch, e.count != 32 { throw RosterWireError.unexpectedKeySet }
        if let fp = ownerCertFingerprint, fp.count != 32 { throw RosterWireError.unexpectedKeySet }
        if let gh = genesisCheckpointHash, gh.count != 32 { throw RosterWireError.unexpectedKeySet }
        switch stateKind {
        case Self.stateKindNoGenesis:
            guard epoch == nil, checkpointSequence == nil, eventSequence == nil,
                  issuedAt == nil, notAfter == nil, checkpointBytes == nil,
                  ownerCertFingerprint == nil, genesisCheckpointHash == nil,
                  conflictingCheckpointBytes == nil,
                  activeMembers.isEmpty, tombstones.isEmpty, eventHashes.isEmpty else {
                throw RosterWireError.unexpectedKeySet
            }
        case Self.stateKindAccepted:
            guard epoch != nil, checkpointSequence != nil, eventSequence != nil,
                  issuedAt != nil, notAfter != nil, checkpointBytes != nil,
                  ownerCertFingerprint != nil, genesisCheckpointHash != nil,
                  conflictingCheckpointBytes == nil,
                  eventHashes.count == tombstones.count,
                  eventSequence == UInt64(exactly: eventHashes.count) else {
                throw RosterWireError.unexpectedKeySet
            }
        case Self.stateKindCheckpointFork, Self.stateKindEventFork:
            guard epoch != nil, checkpointSequence != nil, eventSequence != nil,
                  issuedAt != nil, notAfter != nil, checkpointBytes != nil,
                  ownerCertFingerprint != nil, genesisCheckpointHash != nil,
                  conflictingCheckpointBytes != nil,
                  eventHashes.count == tombstones.count,
                  eventSequence == UInt64(exactly: eventHashes.count) else {
                throw RosterWireError.unexpectedKeySet
            }
        default:
            throw RosterWireError.unexpectedKeySet
        }
        guard eventHashes.allSatisfy({ $0.count == 32 }) else { throw RosterWireError.unexpectedKeySet }
        let mIds = activeMembers.map(\.mId)
        guard Set(mIds).count == mIds.count else { throw RosterWireError.unexpectedKeySet }
        guard mIds == mIds.sorted() else { throw RosterWireError.unexpectedKeySet }
        guard Set(tombstones).count == tombstones.count else { throw RosterWireError.unexpectedKeySet }
        guard Set(mIds).isDisjoint(with: Set(tombstones)) else { throw RosterWireError.unexpectedKeySet }
        self.stateKind = stateKind
        self.hhId = hhId
        self.epoch = epoch
        self.checkpointSequence = checkpointSequence
        self.eventSequence = eventSequence
        self.issuedAt = issuedAt
        self.notAfter = notAfter
        self.floorSecs = floorSecs
        self.activeMembers = activeMembers
        self.tombstones = tombstones
        self.checkpointBytes = checkpointBytes
        self.ownerCertFingerprint = ownerCertFingerprint
        self.genesisCheckpointHash = genesisCheckpointHash
        self.eventHashes = eventHashes
        self.conflictingCheckpointBytes = conflictingCheckpointBytes
    }

    public static let stateKindNoGenesis: UInt8 = 0
    public static let stateKindAccepted: UInt8 = 1
    public static let stateKindCheckpointFork: UInt8 = 2
    public static let stateKindEventFork: UInt8 = 3

    /// Head of the accepted event chain: the last event hash, or the zero hash when no
    /// event has been applied yet. Derived from `eventHashes` rather than stored, so it
    /// cannot drift away from the list it summarises.
    public var eventHeadHash: Data {
        eventHashes.last ?? RosterAuthorityVerifier.zeroHash32
    }

    public var isTerminalFork: Bool {
        stateKind == Self.stateKindCheckpointFork || stateKind == Self.stateKindEventFork
    }

    public func member(for mId: String) -> VerifiedMachineMember? {
        activeMembers.first { $0.mId == mId }
    }

    public func isRevoked(_ mId: String) -> Bool {
        tombstones.contains(mId)
    }
}

public struct RosterSignerBinding: Sendable, Equatable {
    public let v: UInt8
    public let hhId: String
    public let mId: String
    public let machineCert: Data
    public let machineCertFingerprint: Data

    init(hhId: String, mId: String, machineCert: Data, machineCertFingerprint: Data) throws {
        guard !hhId.isEmpty, !mId.isEmpty, !machineCert.isEmpty, machineCertFingerprint.count == 32 else {
            throw RosterWireError.unexpectedKeySet
        }
        self.v = 1
        self.hhId = hhId
        self.mId = mId
        self.machineCert = machineCert
        self.machineCertFingerprint = machineCertFingerprint
    }
}
