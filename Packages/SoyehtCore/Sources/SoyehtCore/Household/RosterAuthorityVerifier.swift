import CryptoKit
import Foundation

public enum RosterAuthorityError: Error, Equatable, Sendable {
    case schemaInvalid
    case canonicalMismatch
    case rootSignatureInvalid
    case ownerSignatureInvalid
    case ownerCertInvalid
    case ownerProvenanceInvalid
    case ownerCaveatsInvalid
    case householdMismatch
    case epochMismatch
    case sequenceInvalid
    case hashChainInvalid
    case eventPrefixInvalid
    case duplicateMember
    case memberSortInvalid
    case tombstoneConflict
    case temporalInvalid
    case forkTerminal
    case keySetInvalid
}

public enum RosterAuthorityVerifier {
    static let checkpointDomain = Data("soyeht/household-machine-roster-checkpoint/v1\u{0}".utf8)
    static let revocationDomain = Data("soyeht/household-machine-roster-revocation/v1\u{0}".utf8)
    static let checkpointKind = "household-machine-roster-checkpoint/v1"
    static let revocationKind = "household-machine-roster-revocation/v1"
    static let maxCheckpointLifetimeSecs: UInt64 = 300
    static let maxFutureSkewSecs: UInt64 = 60

    static let checkpointUnsignedKeys: Set<String> = [
        "v", "kind", "hh_id", "epoch", "checkpoint_sequence",
        "prev_checkpoint_hash", "event_sequence", "event_head_hash",
        "mesh_log_digest", "issued_at", "not_after", "owner_p_id",
        "owner_cert_fingerprint", "active", "revocations",
    ]

    static let revocationUnsignedKeys: Set<String> = [
        "v", "kind", "hh_id", "epoch", "sequence", "prev_event_hash",
        "m_id", "m_pub", "machine_cert_fingerprint", "revoked_at",
        "reason", "cascade", "owner_p_id", "owner_cert_fingerprint",
    ]

    static let memberKeys: Set<String> = [
        "m_id", "m_pub", "machine_cert", "machine_cert_fingerprint",
    ]

    static let personCertKeys: Set<String> = [
        "v", "type", "hh_id", "p_id", "p_pub", "display_name", "caveats",
        "not_before", "not_after", "nonce", "issued_at", "issued_by",
        "owner_auth_tier", "owner_provenance", "signature",
    ]

    static let personCertOperations: Set<String> = [
        "claws.list", "claws.create", "claws.delete", "claws.use", "claws.assign",
        "household.invite", "household.revoke", "household.add_machine", "household.add_device",
        "owner_auth.enroll_initial",
    ]

    static let baselineClawsOperations: Set<String> = [
        "claws.list", "claws.create", "claws.delete", "claws.use", "claws.assign",
    ]

    static let baselineHouseholdOperations: Set<String> = [
        "household.invite", "household.revoke", "household.add_machine",
    ]

    static let ownerProvenances: Set<String> = [
        PersonCert.ownerProvenanceIOSSecureEnclaveOwner,
        PersonCert.ownerProvenanceIPadOSSecureEnclaveOwner,
        PersonCert.ownerProvenanceIOSAppAttestOwner,
        PersonCert.ownerProvenanceIPadOSAppAttestOwner,
    ]

    static let zeroHash32 = Data(repeating: 0, count: 32)

    public static func verifyMachineCertRootBinding(
        certCBOR: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> (mId: String, mPub: Data, fingerprint: Data) {
        let decoded = try RosterWire.decodeCanonical(certCBOR)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        let expectedKeys: Set<String> = [
            "v", "type", "hh_id", "m_id", "m_pub", "hostname",
            "platform", "joined_at", "issued_by", "caveats", "signature",
        ]
        try RosterWire.requireExactKeys(map, expectedKeys)
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let certType = try RosterWire.requireText(map, "type")
        guard certType == "machine" else { throw RosterAuthorityError.schemaInvalid }
        let hhId = try RosterWire.requireText(map, "hh_id")
        guard hhId == expectedHouseholdId else { throw RosterAuthorityError.householdMismatch }
        let mPub = try RosterWire.requireBytes(map, "m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(mPub)
        } catch {
            throw RosterAuthorityError.schemaInvalid
        }
        let mId = try RosterWire.requireText(map, "m_id")
        let derivedMId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
        guard derivedMId == mId else { throw RosterAuthorityError.schemaInvalid }
        let hostname = try RosterWire.requireText(map, "hostname")
        guard isValidHostname(hostname) else { throw RosterAuthorityError.schemaInvalid }
        let platform = try RosterWire.requireText(map, "platform")
        guard MachineCert.Platform(rawValue: platform) != nil else {
            throw RosterAuthorityError.schemaInvalid
        }
        _ = try RosterWire.requireUInt(map, "joined_at")
        let issuedBy = try RosterWire.requireText(map, "issued_by")
        guard issuedBy == hhId else { throw RosterAuthorityError.schemaInvalid }
        guard case .array(let caveats) = map["caveats"], caveats.isEmpty else {
            throw RosterAuthorityError.schemaInvalid
        }
        let fingerprint = Data(SHA256.hash(data: certCBOR))
        let signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(certCBOR, removing: "signature")
        try verifyECDSA(signature: try RosterWire.requireBytes64(map, "signature"),
                        message: signingBytes, publicKey: householdPublicKey)
        return (mId: mId, mPub: mPub, fingerprint: fingerprint)
    }

    private static func isValidHostname(_ hostname: String) -> Bool {
        !hostname.isEmpty
            && hostname.utf8.count <= 255
            && !hostname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public static func verifyPersonCertRootBinding(
        certCBOR: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws -> (pId: String, pPub: Data, fingerprint: Data) {
        let decoded = try RosterWire.decodeCanonical(certCBOR)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        try RosterWire.requireExactKeys(map, personCertKeys)
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let certType = try RosterWire.requireText(map, "type")
        guard certType == "person" else { throw RosterAuthorityError.schemaInvalid }
        let hhId = try RosterWire.requireText(map, "hh_id")
        guard hhId == expectedHouseholdId else { throw RosterAuthorityError.householdMismatch }
        let pPub = try RosterWire.requireBytes(map, "p_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(pPub)
        } catch {
            throw RosterAuthorityError.schemaInvalid
        }
        let pId = try RosterWire.requireText(map, "p_id")
        let derivedPId = try HouseholdIdentifiers.personIdentifier(for: pPub)
        guard derivedPId == pId else { throw RosterAuthorityError.schemaInvalid }
        let displayName = try RosterWire.requireText(map, "display_name")
        guard isValidDisplayName(displayName) else { throw RosterAuthorityError.schemaInvalid }
        let tier = try RosterWire.requireText(map, "owner_auth_tier")
        guard tier == PersonCert.ownerAuthTierStrong else { throw RosterAuthorityError.schemaInvalid }
        let provenance = try RosterWire.requireText(map, "owner_provenance")
        guard ownerProvenances.contains(provenance) else { throw RosterAuthorityError.schemaInvalid }
        let nonce = try RosterWire.requireBytes(map, "nonce")
        guard nonce.count == 16 else { throw RosterAuthorityError.schemaInvalid }
        let notBefore = try RosterWire.requireUInt(map, "not_before")
        let issuedAt = try RosterWire.requireUInt(map, "issued_at")
        guard notBefore <= issuedAt else { throw RosterAuthorityError.temporalInvalid }
        guard effectiveNow >= notBefore else { throw RosterAuthorityError.temporalInvalid }
        guard let notAfterValue = map["not_after"] else { throw RosterAuthorityError.schemaInvalid }
        switch notAfterValue {
        case .null:
            break
        case .unsigned(let notAfter):
            guard effectiveNow < notAfter else { throw RosterAuthorityError.temporalInvalid }
        default:
            throw RosterAuthorityError.schemaInvalid
        }
        let issuedBy = try RosterWire.requireText(map, "issued_by")
        guard issuedBy == hhId else { throw RosterAuthorityError.schemaInvalid }
        try validateOwnerCaveats(map["caveats"])
        let fingerprint = Data(SHA256.hash(data: certCBOR))
        let signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(certCBOR, removing: "signature")
        try verifyECDSA(signature: try RosterWire.requireBytes64(map, "signature"),
                        message: signingBytes, publicKey: householdPublicKey)
        return (pId: pId, pPub: pPub, fingerprint: fingerprint)
    }

    private static func isValidDisplayName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= 64
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validateOwnerCaveats(_ value: HouseholdCBORValue?) throws {
        guard case .array(let caveats) = value else {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
        for caveat in caveats {
            try validateCaveatShape(caveat)
        }
        try requireBaselinePermits(caveats)
    }

    private static func validateCaveatShape(_ value: HouseholdCBORValue) throws {
        guard case .map(let map) = value else {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
        try RosterWire.requireExactKeys(map, ["op", "scope", "constraints"])
        let op = try RosterWire.requireText(map, "op")
        guard personCertOperations.contains(op) else {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
        guard isValidCaveatScope(map["scope"]), isValidCaveatConstraints(map["constraints"]) else {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
    }

    private static func requireBaselinePermits(_ caveats: [HouseholdCBORValue]) throws {
        for op in baselineClawsOperations where !caveats.contains(where: { permitsClaws($0, op: op) }) {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
        for op in baselineHouseholdOperations where !caveats.contains(where: { permitsHousehold($0, op: op) }) {
            throw RosterAuthorityError.ownerCaveatsInvalid
        }
    }

    private static func permitsClaws(_ value: HouseholdCBORValue, op: String) -> Bool {
        guard case .map(let map) = value,
              case .text(let caveatOp) = map["op"], caveatOp == op,
              isAllScope(map["scope"]),
              isNull(map["constraints"]) else { return false }
        return true
    }

    private static func permitsHousehold(_ value: HouseholdCBORValue, op: String) -> Bool {
        guard case .map(let map) = value,
              case .text(let caveatOp) = map["op"], caveatOp == op,
              isNull(map["scope"]),
              isNull(map["constraints"]) else { return false }
        return true
    }

    private static func isValidCaveatScope(_ value: HouseholdCBORValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null:
            return true
        case .map(let map):
            if map.count == 1, case .bool(true) = map["all"] { return true }
            if map.count == 1, case .bool(true) = map["owned_by_self"] { return true }
            if map.count == 1, case .array(let items) = map["specific"] {
                return isSortedUniqueTextArray(items)
            }
            return false
        default:
            return false
        }
    }

    private static func isValidCaveatConstraints(_ value: HouseholdCBORValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null:
            return true
        case .map(let map):
            guard Set(map.keys).isSubset(of: ["machines", "expires_at"]) else { return false }
            if let machines = map["machines"] {
                guard case .array(let items) = machines, isTextArray(items) else { return false }
            }
            if let expiresAt = map["expires_at"] {
                guard case .unsigned = expiresAt else { return false }
            }
            return true
        default:
            return false
        }
    }

    private static func isAllScope(_ value: HouseholdCBORValue?) -> Bool {
        guard let value, case .map(let map) = value,
              map.count == 1, case .bool(true) = map["all"] else { return false }
        return true
    }

    private static func isNull(_ value: HouseholdCBORValue?) -> Bool {
        guard let value, case .null = value else { return false }
        return true
    }

    private static func isSortedUniqueTextArray(_ values: [HouseholdCBORValue]) -> Bool {
        guard !values.isEmpty else { return false }
        var previous: String?
        for value in values {
            guard case .text(let text) = value else { return false }
            if let previous, !(text > previous) { return false }
            previous = text
        }
        return true
    }

    private static func isTextArray(_ values: [HouseholdCBORValue]) -> Bool {
        values.allSatisfy { value in
            if case .text = value { return true }
            return false
        }
    }

    public static func checkpointHash(canonicalUnsigned: Data) -> Data {
        var preimage = Data()
        preimage.append(checkpointDomain)
        preimage.append(canonicalUnsigned)
        return Data(SHA256.hash(data: preimage))
    }

    public static func revocationEventHash(canonicalUnsigned: Data) -> Data {
        var preimage = Data()
        preimage.append(revocationDomain)
        preimage.append(canonicalUnsigned)
        return Data(SHA256.hash(data: preimage))
    }

    public static func verifyCheckpointSignature(
        canonicalCheckpoint: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws {
        let decoded = try RosterWire.decodeCanonical(canonicalCheckpoint)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let kind = try RosterWire.requireText(map, "kind")
        guard kind == checkpointKind else { throw RosterAuthorityError.schemaInvalid }
        try RosterWire.requireExactKeys(map, checkpointUnsignedKeys.union(["owner_person_cert", "signature"]))
        let owner = try verifyOwnerBinding(map: map, expectedHouseholdId: expectedHouseholdId, householdPublicKey: householdPublicKey, effectiveNow: effectiveNow)
        let signature = try RosterWire.requireBytes64(map, "signature")
        let canonicalUnsigned = try canonicalUnsignedSelecting(map, keys: checkpointUnsignedKeys)
        var preimage = Data()
        preimage.append(checkpointDomain)
        preimage.append(canonicalUnsigned)
        try verifyOwnerSignature(signature: signature, message: preimage, publicKey: owner.pPub)
    }

    public static func verifyRevocationSignature(
        canonicalRevocation: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws {
        let decoded = try RosterWire.decodeCanonical(canonicalRevocation)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let kind = try RosterWire.requireText(map, "kind")
        guard kind == revocationKind else { throw RosterAuthorityError.schemaInvalid }
        try RosterWire.requireExactKeys(map, revocationUnsignedKeys.union(["owner_person_cert", "signature"]))
        let owner = try verifyOwnerBinding(map: map, expectedHouseholdId: expectedHouseholdId, householdPublicKey: householdPublicKey, effectiveNow: effectiveNow)
        let signature = try RosterWire.requireBytes64(map, "signature")
        let canonicalUnsigned = try canonicalUnsignedSelecting(map, keys: revocationUnsignedKeys)
        var preimage = Data()
        preimage.append(revocationDomain)
        preimage.append(canonicalUnsigned)
        try verifyOwnerSignature(signature: signature, message: preimage, publicKey: owner.pPub)
    }

    private static func verifyOwnerBinding(
        map: [String: HouseholdCBORValue],
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws -> (pId: String, pPub: Data, fingerprint: Data) {
        let hhId = try RosterWire.requireText(map, "hh_id")
        guard hhId == expectedHouseholdId else { throw RosterAuthorityError.householdMismatch }
        let ownerCert = try RosterWire.requireBytes(map, "owner_person_cert")
        let binding = try verifyPersonCertRootBinding(
            certCBOR: ownerCert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey,
            effectiveNow: effectiveNow
        )
        let ownerPId = try RosterWire.requireText(map, "owner_p_id")
        guard binding.pId == ownerPId else { throw RosterAuthorityError.ownerProvenanceInvalid }
        let ownerFingerprint = try RosterWire.requireBytes32(map, "owner_cert_fingerprint")
        guard binding.fingerprint == ownerFingerprint else { throw RosterAuthorityError.ownerCertInvalid }
        return binding
    }

    private static func canonicalUnsignedSelecting(
        _ map: [String: HouseholdCBORValue],
        keys: Set<String>
    ) throws -> Data {
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in keys {
            guard let value = map[key] else { throw RosterAuthorityError.canonicalMismatch }
            unsigned[key] = value
        }
        return HouseholdCBOR.encode(.map(unsigned))
    }

    private static func verifyOwnerSignature(signature: Data, message: Data, publicKey: Data) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(sig, for: message) else {
                throw RosterAuthorityError.ownerSignatureInvalid
            }
        } catch let error as RosterAuthorityError {
            throw error
        } catch {
            throw RosterAuthorityError.ownerSignatureInvalid
        }
    }

    static func verifyActiveMember(
        _ map: [String: HouseholdCBORValue],
        expectedHouseholdId: String,
        householdPublicKey: Data
    ) throws -> VerifiedActiveMember {
        try RosterWire.requireExactKeys(map, memberKeys)
        let mId = try RosterWire.requireText(map, "m_id")
        let mPub = try RosterWire.requireBytes(map, "m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(mPub)
        } catch {
            throw RosterAuthorityError.schemaInvalid
        }
        let machineCert = try RosterWire.requireBytes(map, "machine_cert")
        let fingerprint = try RosterWire.requireBytes32(map, "machine_cert_fingerprint")
        let binding = try verifyMachineCertRootBinding(
            certCBOR: machineCert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey
        )
        guard binding.mId == mId, binding.mPub == mPub, binding.fingerprint == fingerprint else {
            throw RosterAuthorityError.schemaInvalid
        }
        return VerifiedActiveMember(mId: mId, mPub: mPub, machineCert: machineCert, fingerprint: fingerprint)
    }

    static func verifyRevocationRecord(
        canonicalRevocation: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws -> VerifiedRevocation {
        let decoded = try RosterWire.decodeCanonical(canonicalRevocation)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        return try verifyRevocationMap(
            map,
            expectedHouseholdId: expectedHouseholdId,
            expectedEpoch: nil,
            householdPublicKey: householdPublicKey,
            effectiveNow: effectiveNow
        )
    }

    static func verifyCheckpointRecord(
        canonicalCheckpoint: Data,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws -> VerifiedCheckpoint {
        let decoded = try RosterWire.decodeCanonical(canonicalCheckpoint)
        guard case .map(let map) = decoded else {
            throw RosterAuthorityError.canonicalMismatch
        }
        try RosterWire.requireExactKeys(map, checkpointUnsignedKeys.union(["owner_person_cert", "signature"]))
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let kind = try RosterWire.requireText(map, "kind")
        guard kind == checkpointKind else { throw RosterAuthorityError.schemaInvalid }
        let hhId = try RosterWire.requireText(map, "hh_id")
        guard hhId == expectedHouseholdId else { throw RosterAuthorityError.householdMismatch }
        let epoch = try RosterWire.requireBytes32(map, "epoch")
        let checkpointSequence = try RosterWire.requireUInt(map, "checkpoint_sequence")
        let prevCheckpointHash = try RosterWire.requireBytes32(map, "prev_checkpoint_hash")
        let eventSequence = try RosterWire.requireUInt(map, "event_sequence")
        let eventHeadHash = try RosterWire.requireBytes32(map, "event_head_hash")
        let meshLogDigest = try RosterWire.requireBytes32(map, "mesh_log_digest")
        let issuedAt = try RosterWire.requireUInt(map, "issued_at")
        let notAfter = try RosterWire.requireUInt(map, "not_after")
        guard case .array(let activeValues) = map["active"] else {
            throw RosterAuthorityError.schemaInvalid
        }
        var active: [VerifiedActiveMember] = []
        for value in activeValues {
            guard case .map(let memberMap) = value else { throw RosterAuthorityError.schemaInvalid }
            active.append(try verifyActiveMember(memberMap, expectedHouseholdId: expectedHouseholdId, householdPublicKey: householdPublicKey))
        }
        guard case .array(let revocationValues) = map["revocations"] else {
            throw RosterAuthorityError.schemaInvalid
        }
        var revocations: [VerifiedRevocation] = []
        for value in revocationValues {
            guard case .map(let revocationMap) = value else { throw RosterAuthorityError.schemaInvalid }
            revocations.append(try verifyRevocationMap(
                revocationMap,
                expectedHouseholdId: expectedHouseholdId,
                expectedEpoch: epoch,
                householdPublicKey: householdPublicKey,
                effectiveNow: effectiveNow
            ))
        }
        let owner = try verifyOwnerBinding(map: map, expectedHouseholdId: expectedHouseholdId, householdPublicKey: householdPublicKey, effectiveNow: effectiveNow)
        let signature = try RosterWire.requireBytes64(map, "signature")
        let canonicalUnsigned = try canonicalUnsignedSelecting(map, keys: checkpointUnsignedKeys)
        var preimage = Data()
        preimage.append(checkpointDomain)
        preimage.append(canonicalUnsigned)
        try verifyOwnerSignature(signature: signature, message: preimage, publicKey: owner.pPub)
        try validateGlobalActive(active)
        return VerifiedCheckpoint(
            epoch: epoch,
            checkpointSequence: checkpointSequence,
            prevCheckpointHash: prevCheckpointHash,
            eventSequence: eventSequence,
            eventHeadHash: eventHeadHash,
            meshLogDigest: meshLogDigest,
            issuedAt: issuedAt,
            notAfter: notAfter,
            ownerPId: owner.pId,
            ownerCertFingerprint: owner.fingerprint,
            active: active,
            revocations: revocations,
            rawCBOR: canonicalCheckpoint,
            canonicalUnsigned: canonicalUnsigned,
            checkpointHash: Self.checkpointHash(canonicalUnsigned: canonicalUnsigned)
        )
    }

    private static func verifyRevocationMap(
        _ map: [String: HouseholdCBORValue],
        expectedHouseholdId: String,
        expectedEpoch: Data?,
        householdPublicKey: Data,
        effectiveNow: UInt64
    ) throws -> VerifiedRevocation {
        try RosterWire.requireExactKeys(map, revocationUnsignedKeys.union(["owner_person_cert", "signature"]))
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAuthorityError.schemaInvalid }
        let kind = try RosterWire.requireText(map, "kind")
        guard kind == revocationKind else { throw RosterAuthorityError.schemaInvalid }
        let hhId = try RosterWire.requireText(map, "hh_id")
        guard hhId == expectedHouseholdId else { throw RosterAuthorityError.householdMismatch }
        let epoch = try RosterWire.requireBytes32(map, "epoch")
        if let expectedEpoch {
            guard epoch == expectedEpoch else { throw RosterAuthorityError.epochMismatch }
        }
        let sequence = try RosterWire.requireUInt(map, "sequence")
        let prevEventHash = try RosterWire.requireBytes32(map, "prev_event_hash")
        let mId = try RosterWire.requireText(map, "m_id")
        let mPub = try RosterWire.requireBytes(map, "m_pub")
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(mPub)
        } catch {
            throw RosterAuthorityError.schemaInvalid
        }
        let machineCertFingerprint = try RosterWire.requireBytes32(map, "machine_cert_fingerprint")
        let revokedAt = try RosterWire.requireUInt(map, "revoked_at")
        let reason = try RosterWire.requireUInt(map, "reason")
        guard reason <= 4 else { throw RosterAuthorityError.schemaInvalid }
        let cascade = try RosterWire.requireUInt(map, "cascade")
        guard cascade <= 1 else { throw RosterAuthorityError.schemaInvalid }
        let owner = try verifyOwnerBinding(map: map, expectedHouseholdId: expectedHouseholdId, householdPublicKey: householdPublicKey, effectiveNow: effectiveNow)
        let signature = try RosterWire.requireBytes64(map, "signature")
        let canonicalUnsigned = try canonicalUnsignedSelecting(map, keys: revocationUnsignedKeys)
        var preimage = Data()
        preimage.append(revocationDomain)
        preimage.append(canonicalUnsigned)
        try verifyOwnerSignature(signature: signature, message: preimage, publicKey: owner.pPub)
        return VerifiedRevocation(
            mId: mId,
            mPub: mPub,
            machineCertFingerprint: machineCertFingerprint,
            epoch: epoch,
            sequence: sequence,
            prevEventHash: prevEventHash,
            revokedAt: revokedAt,
            reason: reason,
            cascade: cascade,
            ownerPId: owner.pId,
            ownerCertFingerprint: owner.fingerprint,
            rawCBOR: HouseholdCBOR.encode(.map(map)),
            canonicalUnsigned: canonicalUnsigned,
            eventHash: Self.revocationEventHash(canonicalUnsigned: canonicalUnsigned)
        )
    }

    private static func validateGlobalActive(_ members: [VerifiedActiveMember]) throws {
        var seenPublicKeys = Set<Data>()
        var seenFingerprints = Set<Data>()
        var previousId = ""
        for member in members {
            guard member.mId > previousId else { throw RosterAuthorityError.memberSortInvalid }
            guard seenPublicKeys.insert(member.mPub).inserted else { throw RosterAuthorityError.duplicateMember }
            guard seenFingerprints.insert(member.fingerprint).inserted else { throw RosterAuthorityError.duplicateMember }
            previousId = member.mId
        }
    }

    static func genesisBasis(from checkpoint: VerifiedCheckpoint) throws -> RosterGenesisBasis {
        guard checkpoint.checkpointSequence == 1 else { throw RosterAuthorityError.sequenceInvalid }
        guard checkpoint.prevCheckpointHash == zeroHash32 else { throw RosterAuthorityError.hashChainInvalid }
        guard checkpoint.eventSequence == 0 else { throw RosterAuthorityError.sequenceInvalid }
        guard checkpoint.eventHeadHash == zeroHash32 else { throw RosterAuthorityError.hashChainInvalid }
        guard checkpoint.revocations.isEmpty else { throw RosterAuthorityError.schemaInvalid }
        return RosterGenesisBasis(epoch: checkpoint.epoch, members: checkpoint.active)
    }

    static func rederiveProjection(
        checkpoint: VerifiedCheckpoint,
        basis: RosterGenesisBasis,
        effectiveNow: UInt64
    ) throws -> RosterProjection {
        guard let revocationCount = UInt64(exactly: checkpoint.revocations.count),
              checkpoint.eventSequence == revocationCount else {
            throw RosterAuthorityError.sequenceInvalid
        }
        guard checkpoint.epoch == basis.epoch else { throw RosterAuthorityError.epochMismatch }
        var basisById: [String: VerifiedActiveMember] = [:]
        for member in basis.members {
            basisById[member.mId] = member
        }
        var previousEventHash = zeroHash32
        var revokedIds = Set<String>()
        var tombstones: [VerifiedRevocation] = []
        for (index, revocation) in checkpoint.revocations.enumerated() {
            let (nextIndex, overflow) = index.addingReportingOverflow(1)
            guard !overflow else { throw RosterAuthorityError.sequenceInvalid }
            guard let expectedSequence = UInt64(exactly: nextIndex) else {
                throw RosterAuthorityError.sequenceInvalid
            }
            guard revocation.sequence == expectedSequence else { throw RosterAuthorityError.sequenceInvalid }
            guard revocation.prevEventHash == previousEventHash else { throw RosterAuthorityError.hashChainInvalid }
            guard revocation.ownerCertFingerprint == checkpoint.ownerCertFingerprint else {
                throw RosterAuthorityError.ownerCertInvalid
            }
            guard let basisMember = basisById[revocation.mId] else {
                throw RosterAuthorityError.tombstoneConflict
            }
            guard basisMember.mPub == revocation.mPub,
                  basisMember.fingerprint == revocation.machineCertFingerprint else {
                throw RosterAuthorityError.tombstoneConflict
            }
            guard revokedIds.insert(revocation.mId).inserted else { throw RosterAuthorityError.duplicateMember }
            tombstones.append(revocation)
            previousEventHash = revocation.eventHash
        }
        guard checkpoint.eventHeadHash == previousEventHash else { throw RosterAuthorityError.hashChainInvalid }
        let expectedActive = basis.members.filter { !revokedIds.contains($0.mId) }
        guard checkpoint.active == expectedActive else { throw RosterAuthorityError.tombstoneConflict }
        try validateCheckpointTemporal(issuedAt: checkpoint.issuedAt, notAfter: checkpoint.notAfter, effectiveNow: effectiveNow)
        return RosterProjection(active: checkpoint.active, tombstones: tombstones)
    }

    static func genesisState(from checkpoint: VerifiedCheckpoint, effectiveNow: UInt64) throws -> AcceptedRosterState {
        let basis = try genesisBasis(from: checkpoint)
        let projection = try rederiveProjection(checkpoint: checkpoint, basis: basis, effectiveNow: effectiveNow)
        return AcceptedRosterState(
            checkpoint: checkpoint,
            basis: basis,
            projection: projection,
            predecessorEventSequence: 0,
            predecessorEventHead: zeroHash32
        )
    }

    static func advanceState(
        current: AcceptedRosterState,
        candidate: VerifiedCheckpoint,
        effectiveNow: UInt64
    ) throws -> RosterAdvanceOutcome {
        guard candidate.epoch == current.checkpoint.epoch else { throw RosterAuthorityError.epochMismatch }
        guard candidate.ownerCertFingerprint == current.checkpoint.ownerCertFingerprint else {
            throw RosterAuthorityError.ownerCertInvalid
        }
        let (expectedNextSequence, overflow) = current.checkpoint.checkpointSequence.addingReportingOverflow(1)
        guard !overflow else { throw RosterAuthorityError.sequenceInvalid }
        guard candidate.checkpointSequence == expectedNextSequence else { throw RosterAuthorityError.sequenceInvalid }
        guard candidate.prevCheckpointHash == current.checkpoint.checkpointHash else {
            throw RosterAuthorityError.hashChainInvalid
        }
        guard candidate.issuedAt >= current.checkpoint.issuedAt else { throw RosterAuthorityError.temporalInvalid }
        guard candidate.eventSequence >= current.checkpoint.eventSequence else { throw RosterAuthorityError.sequenceInvalid }
        let candidateProjection = try rederiveProjection(checkpoint: candidate, basis: current.basis, effectiveNow: effectiveNow)
        let currentEventSequence = current.checkpoint.eventSequence
        if candidate.eventSequence == currentEventSequence {
            if candidate.eventHeadHash != current.checkpoint.eventHeadHash {
                return .eventDivergence(.sameSequenceHeadMismatch(
                    sequence: currentEventSequence,
                    currentHead: current.checkpoint.eventHeadHash,
                    candidateHead: candidate.eventHeadHash
                ))
            }
        } else {
            guard let prefixCount = Int(exactly: currentEventSequence) else { throw RosterAuthorityError.sequenceInvalid }
            guard current.projection.tombstones.count == prefixCount else { throw RosterAuthorityError.sequenceInvalid }
            guard candidate.revocations.count >= prefixCount else { throw RosterAuthorityError.sequenceInvalid }
            for index in 0..<prefixCount {
                if candidate.revocations[index].rawCBOR != current.projection.tombstones[index].rawCBOR {
                    return .eventDivergence(.prefixMismatch(index: index))
                }
            }
            if prefixCount > 0, candidate.revocations[prefixCount - 1].eventHash != current.checkpoint.eventHeadHash {
                return .eventDivergence(.intermediateHeadMismatch)
            }
        }
        return .advanced(AcceptedRosterState(
            checkpoint: candidate,
            basis: current.basis,
            projection: candidateProjection,
            predecessorEventSequence: current.checkpoint.eventSequence,
            predecessorEventHead: current.checkpoint.eventHeadHash
        ))
    }

    static func evaluateRoster(
        state: RosterEvaluatorState,
        candidate: VerifiedCheckpoint,
        effectiveNow: UInt64
    ) throws -> RosterEvaluatorState {
        switch state {
        case .noGenesis:
            return .accepted(try genesisState(from: candidate, effectiveNow: effectiveNow))
        case .checkpointFork, .eventFork:
            return state
        case .accepted(let current):
            guard candidate.epoch == current.checkpoint.epoch else { throw RosterAuthorityError.epochMismatch }
            guard candidate.ownerCertFingerprint == current.checkpoint.ownerCertFingerprint else {
                throw RosterAuthorityError.ownerCertInvalid
            }
            if candidate.checkpointSequence < current.checkpoint.checkpointSequence {
                throw RosterAuthorityError.sequenceInvalid
            }
            if candidate.checkpointSequence == current.checkpoint.checkpointSequence {
                if candidate.checkpointHash == current.checkpoint.checkpointHash {
                    return .accepted(current)
                }
                return try evaluateSameSequenceFork(current: current, candidate: candidate, effectiveNow: effectiveNow)
            }
            let (expectedNextSequence, overflow) = current.checkpoint.checkpointSequence.addingReportingOverflow(1)
            guard !overflow else { throw RosterAuthorityError.sequenceInvalid }
            guard candidate.checkpointSequence == expectedNextSequence else { throw RosterAuthorityError.sequenceInvalid }
            let outcome = try advanceState(current: current, candidate: candidate, effectiveNow: effectiveNow)
            switch outcome {
            case .advanced(let next):
                return .accepted(next)
            case .eventDivergence(let divergence):
                return .eventFork(try makeEventFork(current: current, candidate: candidate, divergence: divergence))
            }
        }
    }

    private static func evaluateSameSequenceFork(
        current: AcceptedRosterState,
        candidate: VerifiedCheckpoint,
        effectiveNow: UInt64
    ) throws -> RosterEvaluatorState {
        guard candidate.issuedAt >= current.checkpoint.issuedAt else { throw RosterAuthorityError.temporalInvalid }
        guard candidate.prevCheckpointHash == current.checkpoint.prevCheckpointHash else {
            throw RosterAuthorityError.hashChainInvalid
        }
        let basis: RosterGenesisBasis
        if candidate.checkpointSequence == 1 {
            basis = try genesisBasis(from: candidate)
        } else {
            basis = current.basis
        }
        guard candidate.eventSequence >= current.predecessorEventSequence else {
            throw RosterAuthorityError.sequenceInvalid
        }
        _ = try rederiveProjection(checkpoint: candidate, basis: basis, effectiveNow: effectiveNow)
        guard let predecessorCount = Int(exactly: current.predecessorEventSequence) else {
            throw RosterAuthorityError.sequenceInvalid
        }
        guard candidate.revocations.count >= predecessorCount else { throw RosterAuthorityError.sequenceInvalid }
        let intermediateHead: Data
        if predecessorCount == 0 {
            intermediateHead = zeroHash32
        } else {
            intermediateHead = candidate.revocations[predecessorCount - 1].eventHash
        }
        guard intermediateHead == current.predecessorEventHead else {
            throw RosterAuthorityError.eventPrefixInvalid
        }
        return .checkpointFork(RosterCheckpointFork(
            accepted: current,
            conflicting: candidate,
            acceptedCheckpointHash: current.checkpoint.checkpointHash,
            conflictingCheckpointHash: candidate.checkpointHash
        ))
    }

    private static func makeEventFork(
        current: AcceptedRosterState,
        candidate: VerifiedCheckpoint,
        divergence: RosterEventDivergence
    ) throws -> RosterEventFork {
        let divergentHead: Data
        switch divergence {
        case .sameSequenceHeadMismatch:
            divergentHead = candidate.eventHeadHash
        case .prefixMismatch, .intermediateHeadMismatch:
            let boundary = current.checkpoint.eventSequence
            guard let n = Int(exactly: boundary) else { throw RosterAuthorityError.sequenceInvalid }
            if n == 0 {
                divergentHead = zeroHash32
            } else {
                guard candidate.revocations.count >= n else { throw RosterAuthorityError.sequenceInvalid }
                divergentHead = candidate.revocations[n - 1].eventHash
            }
        }
        return RosterEventFork(
            accepted: current,
            conflicting: candidate,
            divergence: divergence,
            divergentEventHead: divergentHead,
            acceptedCheckpointHash: current.checkpoint.checkpointHash,
            conflictingCheckpointHash: candidate.checkpointHash
        )
    }

    public static func validateCheckpointTemporal(
        issuedAt: UInt64,
        notAfter: UInt64,
        effectiveNow: UInt64
    ) throws {
        let (futureLimit, overflow) = effectiveNow.addingReportingOverflow(Self.maxFutureSkewSecs)
        guard !overflow else { throw RosterAuthorityError.temporalInvalid }
        guard issuedAt <= futureLimit else { throw RosterAuthorityError.temporalInvalid }
        guard effectiveNow <= notAfter else { throw RosterAuthorityError.temporalInvalid }
        let (lifetime, lifetimeOverflow) = notAfter.subtractingReportingOverflow(issuedAt)
        guard !lifetimeOverflow, lifetime <= Self.maxCheckpointLifetimeSecs else {
            throw RosterAuthorityError.temporalInvalid
        }
        guard issuedAt <= notAfter else { throw RosterAuthorityError.temporalInvalid }
    }

    public static func validateActiveMembers(members: [[String: HouseholdCBORValue]]) throws {
        var seenIds = Set<String>()
        var prevId = ""
        for member in members {
            try RosterWire.requireExactKeys(member, memberKeys)
            let mId = try RosterWire.requireText(member, "m_id")
            guard !seenIds.contains(mId) else { throw RosterAuthorityError.duplicateMember }
            guard mId > prevId else { throw RosterAuthorityError.memberSortInvalid }
            seenIds.insert(mId)
            prevId = mId
        }
    }

    static func verifyECDSA(signature: Data, message: Data, publicKey: Data) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(sig, for: message) else {
                throw RosterAuthorityError.rootSignatureInvalid
            }
        } catch let error as RosterAuthorityError {
            throw error
        } catch {
            throw RosterAuthorityError.rootSignatureInvalid
        }
    }
}

struct VerifiedActiveMember: Equatable, Sendable {
    let mId: String
    let mPub: Data
    let machineCert: Data
    let fingerprint: Data
}

struct VerifiedRevocation: Equatable, Sendable {
    let mId: String
    let mPub: Data
    let machineCertFingerprint: Data
    let epoch: Data
    let sequence: UInt64
    let prevEventHash: Data
    let revokedAt: UInt64
    let reason: UInt64
    let cascade: UInt64
    let ownerPId: String
    let ownerCertFingerprint: Data
    let rawCBOR: Data
    let canonicalUnsigned: Data
    let eventHash: Data
}

struct VerifiedCheckpoint: Equatable, Sendable {
    let epoch: Data
    let checkpointSequence: UInt64
    let prevCheckpointHash: Data
    let eventSequence: UInt64
    let eventHeadHash: Data
    let meshLogDigest: Data
    let issuedAt: UInt64
    let notAfter: UInt64
    let ownerPId: String
    let ownerCertFingerprint: Data
    let active: [VerifiedActiveMember]
    let revocations: [VerifiedRevocation]
    let rawCBOR: Data
    let canonicalUnsigned: Data
    let checkpointHash: Data
}

struct RosterGenesisBasis: Equatable, Sendable {
    let epoch: Data
    let members: [VerifiedActiveMember]
}

struct RosterProjection: Equatable, Sendable {
    let active: [VerifiedActiveMember]
    let tombstones: [VerifiedRevocation]
}

struct AcceptedRosterState: Equatable, Sendable {
    let checkpoint: VerifiedCheckpoint
    let basis: RosterGenesisBasis
    let projection: RosterProjection
    let predecessorEventSequence: UInt64
    let predecessorEventHead: Data
}

enum RosterEventDivergence: Equatable, Sendable {
    case sameSequenceHeadMismatch(sequence: UInt64, currentHead: Data, candidateHead: Data)
    case prefixMismatch(index: Int)
    case intermediateHeadMismatch
}

enum RosterAdvanceOutcome: Equatable, Sendable {
    case advanced(AcceptedRosterState)
    case eventDivergence(RosterEventDivergence)
}

struct RosterCheckpointFork: Equatable, Sendable {
    let accepted: AcceptedRosterState
    let conflicting: VerifiedCheckpoint
    let acceptedCheckpointHash: Data
    let conflictingCheckpointHash: Data
}

struct RosterEventFork: Equatable, Sendable {
    let accepted: AcceptedRosterState
    let conflicting: VerifiedCheckpoint
    let divergence: RosterEventDivergence
    let divergentEventHead: Data
    let acceptedCheckpointHash: Data
    let conflictingCheckpointHash: Data
}

enum RosterEvaluatorState: Equatable, Sendable {
    case noGenesis
    case accepted(AcceptedRosterState)
    case checkpointFork(RosterCheckpointFork)
    case eventFork(RosterEventFork)
}
