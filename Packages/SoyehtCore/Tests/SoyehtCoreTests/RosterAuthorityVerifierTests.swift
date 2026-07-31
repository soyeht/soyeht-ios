import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

struct RosterAuthorityVerifierTests {
    // MARK: - Helpers

    private func loadFixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/roster/roster_vectors_v1.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RosterWireError.malformedResponse
        }
        return json
    }

    private func hexData(_ hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw RosterWireError.malformedResponse }
        let chars = Array(hex)
        var data = Data(capacity: hex.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else {
                throw RosterWireError.malformedResponse
            }
            data.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return data
    }

    private func dict(_ json: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = json[key] as? [String: Any] else {
            throw RosterWireError.malformedResponse
        }
        return value
    }

    private func str(_ json: [String: Any], _ key: String) throws -> String {
        guard let value = json[key] as? String else {
            throw RosterWireError.malformedResponse
        }
        return value
    }

    private func rootIds(_ json: [String: Any]) throws -> (hhId: String, pub: Data) {
        let keys = try dict(json, "keys")
        return (hhId: try str(keys, "root_hh_id"), pub: try hexData(try str(keys, "root_pub_hex")))
    }

    private func peekIssuedAt(_ checkpointBytes: Data) throws -> UInt64 {
        guard case .map(let map) = try HouseholdCBOR.decode(checkpointBytes),
              case .unsigned(let issuedAt) = map["issued_at"] else {
            throw RosterWireError.malformedResponse
        }
        return issuedAt
    }

    private func validOwnerCaveats() -> [HouseholdCBORValue] {
        [
            .map(["op": .text("claws.list"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.create"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.delete"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.use"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.assign"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("household.invite"), "scope": .null, "constraints": .null]),
            .map(["op": .text("household.revoke"), "scope": .null, "constraints": .null]),
            .map(["op": .text("household.add_machine"), "scope": .null, "constraints": .null]),
        ]
    }

    // MARK: - Deterministic P-256 keys

    private func rootKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
    }

    private func ownerKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((33...64).map(UInt8.init)))
    }

    // MARK: - Signing helpers

    private func certSigner(_ map: [String: HouseholdCBORValue], with key: P256.Signing.PrivateKey) throws -> Data {
        var unsigned = [String: HouseholdCBORValue]()
        for (k, v) in map {
            guard k != "signature" else { continue }
            unsigned[k] = v
        }
        let toSign = HouseholdCBOR.encode(.map(unsigned))
        let sig = try key.signature(for: toSign)
        var signed = map
        signed["signature"] = .bytes(sig.rawRepresentation)
        return HouseholdCBOR.encode(.map(signed))
    }

    private func checkpointSigner(_ map: [String: HouseholdCBORValue], with key: P256.Signing.PrivateKey) throws -> Data {
        var unsigned = [String: HouseholdCBORValue]()
        for k in RosterAuthorityVerifier.checkpointUnsignedKeys {
            unsigned[k] = map[k]
        }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        var preimage = Data()
        preimage.append(RosterAuthorityVerifier.checkpointDomain)
        preimage.append(canonicalUnsigned)
        let sig = try key.signature(for: preimage)
        var signed = map
        signed["signature"] = .bytes(sig.rawRepresentation)
        return HouseholdCBOR.encode(.map(signed))
    }

    private func revocationSigner(_ map: [String: HouseholdCBORValue], with key: P256.Signing.PrivateKey) throws -> Data {
        var unsigned = [String: HouseholdCBORValue]()
        for k in RosterAuthorityVerifier.revocationUnsignedKeys {
            unsigned[k] = map[k]
        }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        var preimage = Data()
        preimage.append(RosterAuthorityVerifier.revocationDomain)
        preimage.append(canonicalUnsigned)
        let sig = try key.signature(for: preimage)
        var signed = map
        signed["signature"] = .bytes(sig.rawRepresentation)
        return HouseholdCBOR.encode(.map(signed))
    }

    // MARK: - hexData edge cases

    @Test func hexDataRejectsOddLength() throws {
        #expect(throws: RosterWireError.malformedResponse) {
            try self.hexData("abc")
        }
    }

    @Test func hexDataRejectsNonHexChars() throws {
        #expect(throws: RosterWireError.malformedResponse) {
            try self.hexData("0x0g")
        }
    }

    // MARK: - MachineCert (verifyMachineCertRootBinding)

    @Test func machineCertValidRootBinding() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let keys = try dict(json, "keys")
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        let binding = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
            certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub
        )
        #expect(try binding.mId == str(keys, "member1_m_id"))
        #expect(try binding.mPub == hexData(str(keys, "member1_pub_hex")))
        #expect(try binding.fingerprint == hexData(str(dict(json, "member1_cert"), "fingerprint_hex")))
    }

    @Test func machineCertCanonicalExact11Keys() throws {
        let json = try loadFixture()
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(let map) = try HouseholdCBOR.decode(cert) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 11)
        #expect(Set(map.keys) == [
            "v", "type", "hh_id", "m_id", "m_pub", "hostname",
            "platform", "joined_at", "issued_by", "caveats", "signature",
        ])
        guard case .array(let caveats) = map["caveats"] else { Issue.record("caveats"); return }
        #expect(caveats.isEmpty)
    }

    @Test func machineCertRejectsEmptyHostname() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["hostname"] = .text("")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsOversizeHostname() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["hostname"] = .text(String(repeating: "a", count: 256))
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsHostnameWithControlChar() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["hostname"] = .text("test\nhost")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertAcceptsValidPlatforms() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let root = try rootKey()
        let memberId = try HouseholdIdentifiers.identifier(
            for: root.publicKey.compressedRepresentation, kind: .machine
        )
        let memberPub = root.publicKey.compressedRepresentation
        for platform in ["macos", "linux-nix", "linux-other"] {
            var map: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "type": .text("machine"),
                "hh_id": .text(hhId),
                "m_id": .text(memberId),
                "m_pub": .bytes(memberPub),
                "hostname": .text("test"),
                "platform": .text(platform),
                "joined_at": .unsigned(1000),
                "issued_by": .text(hhId),
                "caveats": .array([]),
            ]
            let cert = try certSigner(map, with: root)
            let binding = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: root.publicKey.compressedRepresentation
            )
            #expect(binding.mId == memberId)
        }
    }

    @Test func machineCertRejectsJoinedAtWrongType() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["joined_at"] = .text("not-a-number")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsNonCanonical() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let nonCanonical = Data([0xA1, 0x61, 0x76, 0x18, 0x01])
        #expect(throws: RosterWireError.nonCanonicalResponse) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: nonCanonical, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsFlippedSignature() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert),
              case .bytes(let sig) = map["signature"] else {
            Issue.record("expected signature"); return
        }
        var flipped = sig
        flipped[0] ^= 0xFF
        map["signature"] = .bytes(flipped)
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.rootSignatureInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsWrongHousehold() throws {
        let json = try loadFixture()
        let (_, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        #expect(throws: RosterAuthorityError.householdMismatch) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: cert, expectedHouseholdId: "hh_other", householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsExtraKey() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["bogus"] = .unsigned(99)
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsMissingKey() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map.removeValue(forKey: "hostname")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsWrongType() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["type"] = .text("person")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsBadPlatform() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["platform"] = .text("windows")
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    @Test func machineCertRejectsNonEmptyCaveats() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "member1_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["caveats"] = .array([.map(["op": .text("claws.list"), "scope": .null, "constraints": .null])])
        let tampered = HouseholdCBOR.encode(.map(map))
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyMachineCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub
            )
        }
    }

    // MARK: - PersonCert (verifyPersonCertRootBinding)

    @Test func personCertValidRootBinding() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let keys = try dict(json, "keys")
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        let issuedAt = try peekIssuedAt(cert)
        let binding = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
            certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
        )
        #expect(try binding.pId == str(keys, "owner_p_id"))
        #expect(try binding.pPub == hexData(str(keys, "owner_pub_hex")))
        #expect(try binding.fingerprint == hexData(str(dict(json, "owner_cert"), "fingerprint_hex")))
    }

    @Test func personCertCanonicalExact15Keys() throws {
        let json = try loadFixture()
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(let map) = try HouseholdCBOR.decode(cert) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 15)
        #expect(Set(map.keys) == [
            "v", "type", "hh_id", "p_id", "p_pub", "display_name", "caveats",
            "not_before", "not_after", "nonce", "issued_at", "issued_by",
            "owner_auth_tier", "owner_provenance", "signature",
        ])
        guard case .null = map["not_after"] else { Issue.record("not_after null"); return }
        guard case .text(let tier) = map["owner_auth_tier"] else { Issue.record("tier"); return }
        #expect(tier == "strong")
        guard case .text(let prov) = map["owner_provenance"] else { Issue.record("provenance"); return }
        #expect(prov == "ios-secure-enclave-owner")
    }

    @Test func personCertPermitsAll8BaselineCaveats() throws {
        let json = try loadFixture()
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(let map) = try HouseholdCBOR.decode(cert),
              case .array(let caveats) = map["caveats"] else {
            Issue.record("caveats"); return
        }
        #expect(caveats.count == 8)
        var ops = Set<String>()
        for caveat in caveats {
            guard case .map(let c) = caveat, case .text(let op) = c["op"] else { continue }
            ops.insert(op)
        }
        #expect(ops == [
            "claws.list", "claws.create", "claws.delete", "claws.use", "claws.assign",
            "household.invite", "household.revoke", "household.add_machine",
        ])
    }

    @Test func personCertRejectsWrongHousehold() throws {
        let json = try loadFixture()
        let (_, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        let issuedAt = try peekIssuedAt(cert)
        #expect(throws: RosterAuthorityError.householdMismatch) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: "hh_other", householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertAcceptsAll4ValidProvenances() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_prov"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        let caveats = validOwnerCaveats()
        for provenance in [
            "ios-secure-enclave-owner",
            "ipados-secure-enclave-owner",
            "ios-app-attest-owner",
            "ipados-app-attest-owner",
        ] {
            var map: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "type": .text("person"),
                "hh_id": .text(hhId),
                "p_id": .text(ownerPId),
                "p_pub": .bytes(ownerPub),
                "display_name": .text("Owner"),
                "caveats": .array(caveats),
                "not_before": .unsigned(issuedAt),
                "not_after": .null,
                "nonce": .bytes(nonce),
                "issued_at": .unsigned(issuedAt),
                "issued_by": .text(hhId),
                "owner_auth_tier": .text("strong"),
                "owner_provenance": .text(provenance),
            ]
            let cert = try certSigner(map, with: root)
            let binding = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
            #expect(binding.pId == ownerPId)
        }
    }

    @Test func personCertRejectsDisplayNameTooLong() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_display"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text(String(repeating: "A", count: 65)),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsDisplayNameControlChar() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_dispctrl"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Name\u{0}Bad"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertAcceptsAlternateNotAfter() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_test"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        let notBefore: UInt64 = 900
        let notAfter: UInt64 = 2000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("TestOwner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(notBefore),
            "not_after": .unsigned(notAfter),
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        let binding = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
            certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: 1500
        )
        #expect(binding.pId == ownerPId)
        #expect(binding.pPub == ownerPub)
    }

    @Test func personCertRejectsNotAfterWrongType() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_test"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("TestOwner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .text("bad"),
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsInvalidProvenance() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["owner_provenance"] = .text("bad-provenance")
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsEmptyDisplayName() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["display_name"] = .text("")
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsTemporalNotBeforeAfterIssuedAt() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        guard case .map(var map) = try HouseholdCBOR.decode(cert) else { Issue.record("map"); return }
        map["not_before"] = .unsigned(9999)
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.temporalInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsEffectiveBeforeNotBefore() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let certHex = try str(try dict(json, "owner_cert"), "canonical_hex")
        let cert = try hexData(certHex)
        let issuedAt = try peekIssuedAt(cert)
        #expect(throws: RosterAuthorityError.temporalInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt - 100
            )
        }
    }

    @Test func personCertRejectsExpiredNotAfter() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_test"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1200
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("TestOwner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .unsigned(notAfter),
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.temporalInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: 1300
            )
        }
    }

    @Test func personCertRejectsNonce15() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_nc15"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDE, count: 15)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsNonce17() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_nc17"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDE, count: 17)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsAuthTierNotStrong() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_tier"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("weak"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.schemaInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsMissingBaselineCaveat() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_test"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        let caveats: [HouseholdCBORValue] = [
            .map(["op": .text("claws.list"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.create"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.delete"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.use"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.assign"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("household.invite"), "scope": .null, "constraints": .null]),
            .map(["op": .text("household.revoke"), "scope": .null, "constraints": .null]),
        ]
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("TestOwner"),
            "caveats": .array(caveats),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.ownerCaveatsInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func personCertRejectsBadCaveatShape() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let hhId = "hh_test"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let nonce = Data(repeating: 0xDE, count: 16)
        let issuedAt: UInt64 = 1000
        let caveats: [HouseholdCBORValue] = [
            .map(["op": .text("claws.list"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.create"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.delete"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.use"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("claws.assign"), "scope": .map(["all": .bool(true)]), "constraints": .null]),
            .map(["op": .text("household.invite"), "scope": .null, "constraints": .null]),
            .map(["op": .text("household.revoke"), "scope": .null, "constraints": .null]),
            .map(["op": .text("household.add_machine"), "scope": .map(["bad": .bool(true)]), "constraints": .null]),
        ]
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("TestOwner"),
            "caveats": .array(caveats),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(nonce),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let cert = try certSigner(map, with: root)
        #expect(throws: RosterAuthorityError.ownerCaveatsInvalid) {
            _ = try RosterAuthorityVerifier.verifyPersonCertRootBinding(
                certCBOR: cert, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    // MARK: - Member (4 keys)

    @Test func memberRecordExact4KeysAndBinding() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let keys = try dict(json, "keys")
        let memberHex = try str(try dict(json, "member1"), "canonical_hex")
        let memberBytes = try hexData(memberHex)
        guard case .map(let map) = try HouseholdCBOR.decode(memberBytes) else {
            Issue.record("expected map"); return
        }
        #expect(Set(map.keys) == ["m_id", "m_pub", "machine_cert", "machine_cert_fingerprint"])
        let member = try RosterAuthorityVerifier.verifyActiveMember(
            map, expectedHouseholdId: hhId, householdPublicKey: rootPub
        )
        #expect(try member.mId == str(keys, "member1_m_id"))
        #expect(try member.mPub == hexData(str(keys, "member1_pub_hex")))
        #expect(try member.fingerprint == hexData(str(dict(json, "member1_cert"), "fingerprint_hex")))
    }

    // MARK: - Checkpoint hash oracle

    @Test func checkpointHashOracleDomainPlus15KeyUnsigned() throws {
        let json = try loadFixture()
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(let fullMap) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.checkpointUnsignedKeys {
            guard let val = fullMap[key] else { Issue.record("missing \(key)"); return }
            unsigned[key] = val
        }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        let computedHash = RosterAuthorityVerifier.checkpointHash(canonicalUnsigned: canonicalUnsigned)
        let oracleHash = try hexData(try str(genesis, "hash_hex"))
        #expect(computedHash == oracleHash)
        let preimageHex = try str(genesis, "preimage_hex")
        let expectedDomain = Data("soyeht/household-machine-roster-checkpoint/v1\u{0}".utf8)
        #expect(try hexData(preimageHex).starts(with: expectedDomain))
        let preimageUnsigned = try hexData(preimageHex).dropFirst(expectedDomain.count)
        #expect(preimageUnsigned == canonicalUnsigned)
    }

    @Test func checkpointUnsignedMapHasExact15Keys() throws {
        #expect(RosterAuthorityVerifier.checkpointUnsignedKeys.count == 15)
        #expect(RosterAuthorityVerifier.checkpointUnsignedKeys == [
            "v", "kind", "hh_id", "epoch", "checkpoint_sequence",
            "prev_checkpoint_hash", "event_sequence", "event_head_hash",
            "mesh_log_digest", "issued_at", "not_after", "owner_p_id",
            "owner_cert_fingerprint", "active", "revocations",
        ])
    }

    @Test func checkpointFullMapHasExact17Keys() throws {
        let json = try loadFixture()
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(let map) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 17)
        #expect(Set(map.keys) == RosterAuthorityVerifier.checkpointUnsignedKeys.union(["owner_person_cert", "signature"]))
    }

    @Test func revocationUnsignedMapHasExact14Keys() throws {
        #expect(RosterAuthorityVerifier.revocationUnsignedKeys.count == 14)
        #expect(RosterAuthorityVerifier.revocationUnsignedKeys == [
            "v", "kind", "hh_id", "epoch", "sequence", "prev_event_hash",
            "m_id", "m_pub", "machine_cert_fingerprint", "revoked_at",
            "reason", "cascade", "owner_p_id", "owner_cert_fingerprint",
        ])
    }

    @Test func revocationFullMapHasExact16Keys() throws {
        let json = try loadFixture()
        let revocation = try dict(json, "revocation")
        let bytes = try hexData(try str(revocation, "canonical_hex"))
        guard case .map(let map) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 16)
        #expect(Set(map.keys) == RosterAuthorityVerifier.revocationUnsignedKeys.union(["owner_person_cert", "signature"]))
    }

    // MARK: - Checkpoint verification

    @Test func checkpointExact17KeysAndPreimage() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(let map) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 17)
        let preimage = try hexData(try str(genesis, "preimage_hex"))
        let domain = Data("soyeht/household-machine-roster-checkpoint/v1\u{0}".utf8)
        #expect(preimage.starts(with: domain))
        let issuedAt = try peekIssuedAt(bytes)
        let checkpoint = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: bytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
        )
        #expect(checkpoint.checkpointSequence == 1)
        #expect(checkpoint.rawCBOR == bytes)
    }

    @Test func checkpointRejectsWrongSignature() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(var map) = try HouseholdCBOR.decode(bytes),
              case .bytes(let sig) = map["signature"] else {
            Issue.record("expected signature"); return
        }
        var flipped = sig
        flipped[0] ^= 0xFF
        map["signature"] = .bytes(flipped)
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.ownerSignatureInvalid) {
            _ = try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    // MARK: - Revocation verifier (full)

    @Test func revocationExact16KeysAndEventHash() throws {
        let json = try loadFixture()
        let revocation = try dict(json, "revocation")
        let bytes = try hexData(try str(revocation, "canonical_hex"))
        guard case .map(let map) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        #expect(map.count == 16)
        let preimage = try hexData(try str(revocation, "preimage_hex"))
        let domain = Data("soyeht/household-machine-roster-revocation/v1\u{0}".utf8)
        #expect(preimage.starts(with: domain))
        let unsigned = Data(preimage.dropFirst(domain.count))
        #expect(try RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: unsigned) == hexData(str(revocation, "event_hash_hex")))
    }

    @Test func revocationVerifierFullRoundTrip() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let keys = try dict(json, "keys")
        let revDict = try dict(json, "revocation")
        let bytes = try hexData(try str(revDict, "canonical_hex"))
        let issuedAt: UInt64 = 1000
        let verified = try RosterAuthorityVerifier.verifyRevocationRecord(
            canonicalRevocation: bytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
        )
        #expect(verified.rawCBOR == bytes)
        #expect(try verified.mId == str(keys, "member1_m_id"))
        #expect(try verified.mPub == hexData(str(keys, "member1_pub_hex")))
        #expect(try verified.machineCertFingerprint == hexData(str(dict(json, "member1_cert"), "fingerprint_hex")))
        #expect(verified.sequence == 1)
        #expect(verified.reason == 0)
        #expect(verified.cascade == 0)
        #expect(verified.canonicalUnsigned.count > 0)
        let domain = Data("soyeht/household-machine-roster-revocation/v1\u{0}".utf8)
        var expectedPreimage = Data()
        expectedPreimage.append(domain)
        expectedPreimage.append(verified.canonicalUnsigned)
        #expect(verified.eventHash == Data(SHA256.hash(data: expectedPreimage)))
        #expect(try verified.eventHash == hexData(str(revDict, "event_hash_hex")))
    }

    @Test func revocationRejectsFlippedSignature() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let revDict = try dict(json, "revocation")
        let bytes = try hexData(try str(revDict, "canonical_hex"))
        guard case .map(var map) = try HouseholdCBOR.decode(bytes),
              case .bytes(let sig) = map["signature"] else {
            Issue.record("expected signature"); return
        }
        var flipped = sig
        flipped[0] ^= 0xFF
        map["signature"] = .bytes(flipped)
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt: UInt64 = 1000
        #expect(throws: RosterAuthorityError.ownerSignatureInvalid) {
            _ = try RosterAuthorityVerifier.verifyRevocationRecord(
                canonicalRevocation: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func revocationRejectsHouseholdMismatch() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let revDict = try dict(json, "revocation")
        let bytes = try hexData(try str(revDict, "canonical_hex"))
        #expect(throws: RosterAuthorityError.householdMismatch) {
            _ = try RosterAuthorityVerifier.verifyRevocationRecord(
                canonicalRevocation: bytes, expectedHouseholdId: "hh_other", householdPublicKey: rootPub, effectiveNow: 1000
            )
        }
    }

    // MARK: - Tamper cases from fixture

    @Test func tamperCheckpointSignatureFlipByte0() throws {
        let json = try loadFixture()
        let tamperCases = try dict(json, "tamper_cases")
        let sigCase = try dict(tamperCases, "checkpoint_signature_flip_byte0")
        let originalSigHex = try str(sigCase, "original_hex")
        let tamperedSigHex = try str(sigCase, "tampered_hex")
        let originalSig = try hexData(originalSigHex)
        let tamperedSig = try hexData(tamperedSigHex)

        let (hhId, rootPub) = try rootIds(json)
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(var map) = try HouseholdCBOR.decode(bytes),
              case .bytes(let sig) = map["signature"] else {
            Issue.record("expected signature"); return
        }
        #expect(sig == originalSig)
        #expect(originalSig.count == tamperedSig.count)
        var diffCount = 0
        var diffIdx = -1
        for i in 0..<originalSig.count where originalSig[i] != tamperedSig[i] {
            diffCount += 1
            diffIdx = i
        }
        #expect(diffCount == 1)
        #expect(diffIdx == 0)
        #expect(sig[0] != tamperedSig[0])
        map["signature"] = .bytes(tamperedSig)
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.ownerSignatureInvalid) {
            _ = try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func tamperCheckpointIssuedAtPlusOne() throws {
        let json = try loadFixture()
        let tamperCases = try dict(json, "tamper_cases")
        let issuedCase = try dict(tamperCases, "checkpoint_issued_at_plus_one")
        guard let byteOffset = issuedCase["byte_offset"] as? Int else {
            Issue.record("missing byte_offset"); return
        }
        let originalByteHex = try str(issuedCase, "original_byte_hex")
        let tamperedByteHex = try str(issuedCase, "tampered_byte_hex")
        #expect(originalByteHex == "e8")
        #expect(tamperedByteHex == "e9")

        let preimageOriginal = try hexData(try str(issuedCase, "preimage_original_hex"))
        let preimageTampered = try hexData(try str(issuedCase, "preimage_tampered_hex"))
        #expect(preimageOriginal.count == preimageTampered.count)
        #expect(preimageOriginal[byteOffset] == 0xe8)
        #expect(preimageTampered[byteOffset] == 0xe9)
        #expect(preimageOriginal[0..<byteOffset] == preimageTampered[0..<byteOffset])
        #expect(preimageOriginal[(byteOffset + 1)...] == preimageTampered[(byteOffset + 1)...])

        let (hhId, rootPub) = try rootIds(json)
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(var map) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        guard case .unsigned(let originalIssuedAt) = map["issued_at"] else {
            Issue.record("issued_at"); return
        }
        map["issued_at"] = .unsigned(originalIssuedAt + 1)
        let tampered = HouseholdCBOR.encode(.map(map))
        let issuedAt = try peekIssuedAt(tampered)
        #expect(throws: RosterAuthorityError.ownerSignatureInvalid) {
            _ = try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: tampered, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }
    }

    @Test func tamperCheckpointHashMismatch() throws {
        let json = try loadFixture()
        let tamperCases = try dict(json, "tamper_cases")
        let hashCase = try dict(tamperCases, "checkpoint_hash_mismatch")
        let originalHashHex = try str(hashCase, "original_hex")
        let tamperedHashHex = try str(hashCase, "tampered_hex")

        let genesis = try dict(json, "genesis_checkpoint")
        let genesisHash = try hexData(try str(genesis, "hash_hex"))
        #expect(try genesisHash == hexData(originalHashHex))
        let wrongPrevHash = try hexData(tamperedHashHex)
        #expect(wrongPrevHash != genesisHash)

        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_hash"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCertMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ]
        let personCert = try certSigner(personCertMap, with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        func makeCP(seq: UInt64, prev: Data) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(prev),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(Data(repeating: 0xDD, count: 32)),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let genesisCp = try makeCP(seq: 1, prev: Data(repeating: 0, count: 32))
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesisCp, effectiveNow: issuedAt)
        let badNext = try makeCP(seq: 2, prev: wrongPrevHash)
        #expect(throws: RosterAuthorityError.hashChainInvalid) {
            _ = try RosterAuthorityVerifier.advanceState(
                current: genesisState, candidate: badNext, effectiveNow: issuedAt
            )
        }
    }

    // MARK: - Genesis / rederive / advance

    @Test func genesisStateFromGenesisCheckpoint() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let bytes = try hexData(try str(try dict(json, "genesis_checkpoint"), "canonical_hex"))
        let issuedAt = try peekIssuedAt(bytes)
        let checkpoint = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: bytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
        )
        let state = try RosterAuthorityVerifier.genesisState(from: checkpoint, effectiveNow: issuedAt)
        #expect(state.checkpoint.checkpointSequence == 1)
        #expect(state.checkpoint.epoch == checkpoint.epoch)
        #expect(state.projection.active.count == 2)
        #expect(state.projection.tombstones.isEmpty)
    }

    @Test func rederiveProjectionAccepted() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let refreshBytes = try hexData(refreshHex)
        let issuedAt = try peekIssuedAt(refreshBytes)
        let checkpoint = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
        )
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let projection = try RosterAuthorityVerifier.rederiveProjection(
            checkpoint: checkpoint, basis: genesisState.basis, effectiveNow: issuedAt
        )
        let keys = try dict(json, "keys")
        #expect(projection.active.count == 1)
        #expect(try projection.active.first?.mId == str(keys, "member2_m_id"))
        #expect(projection.tombstones.count == 1)
        #expect(try projection.tombstones.first?.mId == str(keys, "member1_m_id"))
    }

    @Test func advanceStateLinearNext() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let next) = outcome else {
            Issue.record("expected advanced"); return
        }
        #expect(next.checkpoint.checkpointSequence == refresh.checkpointSequence)
    }

    // MARK: - Evaluator

    @Test func evaluateRosterAcceptsSameCheckpointIdempotent() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(genesisState), candidate: genesis, effectiveNow: genesisIssuedAt
        )
        guard case .accepted = outcome else {
            Issue.record("expected accepted (same checkpoint, idempotent)"); return
        }
    }

    @Test func evaluateRosterFromNoGenesisAcceptsGenesis() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .noGenesis, candidate: genesis, effectiveNow: genesisIssuedAt
        )
        guard case .accepted = outcome else {
            Issue.record("expected accepted from noGenesis"); return
        }
    }

    @Test func terminalForkIsAbsorbing() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let forkProjection = try RosterAuthorityVerifier.rederiveProjection(
            checkpoint: genesis, basis: genesisState.basis, effectiveNow: genesisIssuedAt
        )
        let forkState = AcceptedRosterState(
            checkpoint: genesis, basis: genesisState.basis, projection: forkProjection,
            predecessorEventSequence: 0, predecessorEventHead: Data(repeating: 0, count: 32)
        )
        let fork = RosterCheckpointFork(
            accepted: forkState, conflicting: genesis,
            acceptedCheckpointHash: genesis.checkpointHash, conflictingCheckpointHash: genesis.checkpointHash
        )
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .checkpointFork(fork), candidate: genesis, effectiveNow: genesisIssuedAt
        )
        guard case .checkpointFork = outcome else {
            Issue.record("terminal fork must be absorbing/unchanged"); return
        }
    }

    @Test func evaluateSameEventSeqAndHeadNoFalsePrefixFork() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let current) = advanced else { Issue.record("expected advanced from oracle"); return }

        let oracleRev = current.projection.tombstones[0]
        let diffSignature = oracleRev.rawCBOR.togglingLastBit()
        let revCopy = VerifiedRevocation(
            mId: oracleRev.mId, mPub: oracleRev.mPub,
            machineCertFingerprint: oracleRev.machineCertFingerprint,
            epoch: oracleRev.epoch, sequence: oracleRev.sequence,
            prevEventHash: oracleRev.prevEventHash,
            revokedAt: oracleRev.revokedAt, reason: oracleRev.reason,
            cascade: oracleRev.cascade,
            ownerPId: oracleRev.ownerPId,
            ownerCertFingerprint: oracleRev.ownerCertFingerprint,
            rawCBOR: diffSignature,
            canonicalUnsigned: oracleRev.canonicalUnsigned,
            eventHash: oracleRev.eventHash
        )
        let candidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: current.checkpoint.eventSequence,
            eventHeadHash: current.checkpoint.eventHeadHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: current.checkpoint.active,
            revocations: [revCopy],
            rawCBOR: oracleRev.rawCBOR,
            canonicalUnsigned: oracleRev.canonicalUnsigned,
            checkpointHash: current.checkpoint.checkpointHash
        )
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: current, candidate: candidate, effectiveNow: refreshIssuedAt
        )
        guard case .advanced = outcome else {
            Issue.record("expected advanced (same event seq/head, no false prefix fork)"); return
        }
    }

    @Test func evaluateSameSeqHeadMismatchEventDivergence() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let current) = advanced else { Issue.record("expected advanced from oracle"); return }

        let basisMembers = current.basis.members
        let revokedMId = current.projection.tombstones[0].mId
        guard let otherMember = basisMembers.first(where: { $0.mId != revokedMId }) else {
            Issue.record("need at least 2 basis members"); return
        }

        let revMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(current.checkpoint.epoch),
            "sequence": .unsigned(1), "prev_event_hash": .bytes(RosterAuthorityVerifier.zeroHash32),
            "m_id": .text(otherMember.mId), "m_pub": .bytes(otherMember.mPub),
            "machine_cert_fingerprint": .bytes(otherMember.fingerprint),
            "revoked_at": .unsigned(current.checkpoint.issuedAt),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(current.checkpoint.ownerPId),
            "owner_cert_fingerprint": .bytes(current.checkpoint.ownerCertFingerprint),
        ]
        var revUnsignedMap: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { revUnsignedMap[key] = revMap[key] }
        let revCanonical = HouseholdCBOR.encode(.map(revUnsignedMap))
        let revEventHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: revCanonical)
        var revFullMap = revMap
        revFullMap["signature"] = .bytes(Data(repeating: 0xAA, count: 64))
        let revRaw = HouseholdCBOR.encode(.map(revFullMap))
        let revB = VerifiedRevocation(
            mId: otherMember.mId, mPub: otherMember.mPub,
            machineCertFingerprint: otherMember.fingerprint,
            epoch: current.checkpoint.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32,
            revokedAt: current.checkpoint.issuedAt,
            reason: 1, cascade: 0,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, eventHash: revEventHash
        )
        let expectedActive = basisMembers.filter { $0.mId != otherMember.mId }

        let candidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: 1, eventHeadHash: revEventHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: expectedActive, revocations: [revB],
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, checkpointHash: revEventHash
        )
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: current, candidate: candidate, effectiveNow: refreshIssuedAt
        )
        guard case .eventDivergence(.sameSequenceHeadMismatch) = outcome else {
            Issue.record("expected eventDivergence(.sameSequenceHeadMismatch)"); return
        }
    }

    @Test func evaluateFreeMeshChangesAdvanced() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_mesh"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        let activeMember = try {
            let mId = try HouseholdIdentifiers.identifier(for: root.publicKey.compressedRepresentation, kind: .machine)
            var m: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "type": .text("machine"),
                "hh_id": .text(hhId),
                "m_id": .text(mId),
                "m_pub": .bytes(root.publicKey.compressedRepresentation),
                "hostname": .text("mac"),
                "platform": .text("macos"),
                "joined_at": .unsigned(issuedAt),
                "issued_by": .text(hhId),
                "caveats": .array([]),
            ]
            let cert = try certSigner(m, with: root)
            let fp = Data(SHA256.hash(data: cert))
            return ["m_id": .text(mId), "m_pub": .bytes(root.publicKey.compressedRepresentation),
                    "machine_cert": .bytes(cert), "machine_cert_fingerprint": .bytes(fp)] as [String: HouseholdCBORValue]
        }()

        func makeCP(seq: UInt64, prev: Data, mesh: Data) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(prev),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(mesh),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([.map(activeMember)]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let cpA = try makeCP(seq: 1, prev: Data(repeating: 0, count: 32), mesh: Data(repeating: 0xAA, count: 32))
        let genesisState = try RosterAuthorityVerifier.genesisState(from: cpA, effectiveNow: issuedAt)
        let cpB = try makeCP(seq: 2, prev: cpA.checkpointHash, mesh: Data(repeating: 0xBB, count: 32))
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: cpB, effectiveNow: issuedAt
        )
        guard case .advanced = outcome else {
            Issue.record("expected advanced (mesh change alone not a divergence)"); return
        }
    }

    @Test func evaluateRealCheckpointFork() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_fork_test"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("ForkOwner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        let activeMember = try {
            let mPub = root.publicKey.compressedRepresentation
            let mId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
            var m: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "type": .text("machine"),
                "hh_id": .text(hhId),
                "m_id": .text(mId),
                "m_pub": .bytes(mPub),
                "hostname": .text("mac-fork"),
                "platform": .text("macos"),
                "joined_at": .unsigned(issuedAt),
                "issued_by": .text(hhId),
                "caveats": .array([]),
            ]
            let cert = try certSigner(m, with: root)
            let fp = Data(SHA256.hash(data: cert))
            return ["m_id": .text(mId), "m_pub": .bytes(mPub),
                    "machine_cert": .bytes(cert), "machine_cert_fingerprint": .bytes(fp)] as [String: HouseholdCBORValue]
        }()

        func makeCP(mesh: Data, seq: UInt64, prev: Data) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(prev),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(mesh),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([.map(activeMember)]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let genesisHash = Data(repeating: 0, count: 32)
        let cpA = try makeCP(mesh: Data(repeating: 0xCA, count: 32), seq: 1, prev: genesisHash)
        let genesisState = try RosterAuthorityVerifier.genesisState(from: cpA, effectiveNow: issuedAt)
        let cpB = try makeCP(mesh: Data(repeating: 0xCB, count: 32), seq: 1, prev: genesisHash)
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(genesisState), candidate: cpB, effectiveNow: issuedAt
        )
        guard case .checkpointFork(let fork) = outcome else {
            Issue.record("expected checkpointFork"); return
        }
        #expect(fork.accepted.checkpoint.checkpointHash != fork.conflicting.checkpointHash)
    }

    @Test func evaluateCandidateNeverForksWrongEpoch() throws {
        let root = try rootKey()
        let hhId = "hh_no_fork"
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epochA = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300
        let rootPub = root.publicKey.compressedRepresentation

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        let activeMember = try {
            let mPub = root.publicKey.compressedRepresentation
            let mId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
            var m: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "type": .text("machine"),
                "hh_id": .text(hhId),
                "m_id": .text(mId),
                "m_pub": .bytes(mPub),
                "hostname": .text("mac-test"),
                "platform": .text("macos"),
                "joined_at": .unsigned(issuedAt),
                "issued_by": .text(hhId),
                "caveats": .array([]),
            ]
            let cert = try certSigner(m, with: root)
            let fp = Data(SHA256.hash(data: cert))
            return ["m_id": .text(mId), "m_pub": .bytes(mPub),
                    "machine_cert": .bytes(cert), "machine_cert_fingerprint": .bytes(fp)] as [String: HouseholdCBORValue]
        }()

        func makeCP(epoch: Data, seq: UInt64) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(seq == 1 ? Data(repeating: 0, count: 32) : Data(repeating: 0x01, count: 32)),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(Data(repeating: 0xDD, count: 32)),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([.map(activeMember)]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let cpA = try makeCP(epoch: epochA, seq: 1)
        let genesisState = try RosterAuthorityVerifier.genesisState(from: cpA, effectiveNow: issuedAt)
        let epochB = Data(repeating: 0xBB, count: 32)
        let cpB = try makeCP(epoch: epochB, seq: 2)
        #expect(throws: RosterAuthorityError.epochMismatch) {
            _ = try RosterAuthorityVerifier.evaluateRoster(
                state: .accepted(genesisState), candidate: cpB, effectiveNow: issuedAt
            )
        }
    }

    @Test func evaluateReplaySameSequenceSameHashAccepted() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(genesisState), candidate: genesis, effectiveNow: genesisIssuedAt
        )
        guard case .accepted = outcome else {
            Issue.record("expected accepted (replay)"); return
        }
    }

    @Test func evaluateGapSequenceJumpRejected() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_gap"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))
        let mPub = root.publicKey.compressedRepresentation
        let mId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
        let memberCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("machine"),
            "hh_id": .text(hhId),
            "m_id": .text(mId),
            "m_pub": .bytes(mPub),
            "hostname": .text("mac"),
            "platform": .text("macos"),
            "joined_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "caveats": .array([]),
        ], with: root)
        let mFp = Data(SHA256.hash(data: memberCert))
        let memberMap: [String: HouseholdCBORValue] = [
            "m_id": .text(mId), "m_pub": .bytes(mPub),
            "machine_cert": .bytes(memberCert), "machine_cert_fingerprint": .bytes(mFp),
        ]

        func makeCP(seq: UInt64, prev: Data) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(prev),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(Data(repeating: 0xDD, count: 32)),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([.map(memberMap)]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let genesis = try makeCP(seq: 1, prev: Data(repeating: 0, count: 32))
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: issuedAt)
        let gap = try makeCP(seq: 3, prev: genesis.checkpointHash)
        #expect(throws: RosterAuthorityError.sequenceInvalid) {
            _ = try RosterAuthorityVerifier.evaluateRoster(
                state: .accepted(genesisState), candidate: gap, effectiveNow: issuedAt
            )
        }
    }

    @Test func evaluateOverflowSequenceLessThanCurrentRejected() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let nextState) = advanced else {
            Issue.record("expected advanced"); return
        }
        #expect(throws: RosterAuthorityError.sequenceInvalid) {
            _ = try RosterAuthorityVerifier.evaluateRoster(
                state: .accepted(nextState), candidate: genesis, effectiveNow: genesisIssuedAt
            )
        }
    }

    @Test func evaluateTemporalFutureIssuedAtRejected() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_temporal"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        let mPub = root.publicKey.compressedRepresentation
        let mId = try HouseholdIdentifiers.identifier(for: mPub, kind: .machine)
        let memberCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("machine"),
            "hh_id": .text(hhId),
            "m_id": .text(mId),
            "m_pub": .bytes(mPub),
            "hostname": .text("mac-test"),
            "platform": .text("macos"),
            "joined_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "caveats": .array([]),
        ], with: root)
        let mFp = Data(SHA256.hash(data: memberCert))
        let memberMap: [String: HouseholdCBORValue] = [
            "m_id": .text(mId), "m_pub": .bytes(mPub),
            "machine_cert": .bytes(memberCert), "machine_cert_fingerprint": .bytes(mFp),
        ]

        var cpMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "kind": .text("household-machine-roster-checkpoint/v1"),
            "hh_id": .text(hhId),
            "epoch": .bytes(epoch),
            "checkpoint_sequence": .unsigned(1),
            "prev_checkpoint_hash": .bytes(Data(repeating: 0, count: 32)),
            "event_sequence": .unsigned(0),
            "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
            "mesh_log_digest": .bytes(Data(repeating: 0xDD, count: 32)),
            "issued_at": .unsigned(issuedAt),
            "not_after": .unsigned(notAfter),
            "owner_p_id": .text(ownerPId),
            "owner_cert_fingerprint": .bytes(personCertFingerprint),
            "active": .array([.map(memberMap)]),
            "revocations": .array([]),
            "owner_person_cert": .bytes(personCert),
        ]
        let cpCBOR = try checkpointSigner(cpMap, with: owner)
        let effectiveNow: UInt64 = 100
        #expect(throws: RosterAuthorityError.temporalInvalid) {
            _ = try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: effectiveNow
            )
        }
    }

    @Test func evaluateEventForkViaEvaluateRoster() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let current) = advanced else { Issue.record("expected advanced from oracle"); return }

        let basisMembers = current.basis.members
        let revokedMId = current.projection.tombstones[0].mId
        guard let otherMember = basisMembers.first(where: { $0.mId != revokedMId }) else {
            Issue.record("need at least 2 basis members"); return
        }
        let revMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(current.checkpoint.epoch),
            "sequence": .unsigned(1), "prev_event_hash": .bytes(RosterAuthorityVerifier.zeroHash32),
            "m_id": .text(otherMember.mId), "m_pub": .bytes(otherMember.mPub),
            "machine_cert_fingerprint": .bytes(otherMember.fingerprint),
            "revoked_at": .unsigned(current.checkpoint.issuedAt),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(current.checkpoint.ownerPId),
            "owner_cert_fingerprint": .bytes(current.checkpoint.ownerCertFingerprint),
        ]
        var revUnsignedMap: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { revUnsignedMap[key] = revMap[key] }
        let revCanonical = HouseholdCBOR.encode(.map(revUnsignedMap))
        let revEventHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: revCanonical)
        var revFullMap = revMap
        revFullMap["signature"] = .bytes(Data(repeating: 0xAA, count: 64))
        let revRaw = HouseholdCBOR.encode(.map(revFullMap))
        let revB = VerifiedRevocation(
            mId: otherMember.mId, mPub: otherMember.mPub,
            machineCertFingerprint: otherMember.fingerprint,
            epoch: current.checkpoint.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32,
            revokedAt: current.checkpoint.issuedAt,
            reason: 1, cascade: 0,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, eventHash: revEventHash
        )
        let expectedActive = basisMembers.filter { $0.mId != otherMember.mId }
        let candidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: 1, eventHeadHash: revEventHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: expectedActive, revocations: [revB],
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, checkpointHash: revEventHash
        )
        let outcome = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(current), candidate: candidate, effectiveNow: refreshIssuedAt
        )
        guard case .eventFork(let ef) = outcome else {
            Issue.record("expected eventFork"); return
        }
        guard case .sameSequenceHeadMismatch = ef.divergence else {
            Issue.record("expected sameSequenceHeadMismatch divergence"); return
        }
    }

    @Test func evaluateGrowthPrefixMismatch() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let current) = advanced else { Issue.record("expected advanced from oracle"); return }

        let oracleRev = current.projection.tombstones[0]
        let basisMembers = current.basis.members
        let revokedMId = oracleRev.mId
        guard let otherMember = basisMembers.first(where: { $0.mId != revokedMId }) else {
            Issue.record("need at least 2 basis members"); return
        }

        let diffSignature = oracleRev.rawCBOR.togglingLastBit()
        let r1Prime = VerifiedRevocation(
            mId: oracleRev.mId, mPub: oracleRev.mPub,
            machineCertFingerprint: oracleRev.machineCertFingerprint,
            epoch: oracleRev.epoch, sequence: oracleRev.sequence,
            prevEventHash: oracleRev.prevEventHash,
            revokedAt: oracleRev.revokedAt, reason: oracleRev.reason,
            cascade: oracleRev.cascade,
            ownerPId: oracleRev.ownerPId,
            ownerCertFingerprint: oracleRev.ownerCertFingerprint,
            rawCBOR: diffSignature,
            canonicalUnsigned: oracleRev.canonicalUnsigned,
            eventHash: oracleRev.eventHash
        )
        let r2Map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(current.checkpoint.epoch),
            "sequence": .unsigned(2), "prev_event_hash": .bytes(oracleRev.eventHash),
            "m_id": .text(otherMember.mId), "m_pub": .bytes(otherMember.mPub),
            "machine_cert_fingerprint": .bytes(otherMember.fingerprint),
            "revoked_at": .unsigned(current.checkpoint.issuedAt),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(current.checkpoint.ownerPId),
            "owner_cert_fingerprint": .bytes(current.checkpoint.ownerCertFingerprint),
        ]
        var r2UnsignedMap: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { r2UnsignedMap[key] = r2Map[key] }
        let r2Canonical = HouseholdCBOR.encode(.map(r2UnsignedMap))
        let r2EventHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: r2Canonical)
        var r2FullMap = r2Map
        r2FullMap["signature"] = .bytes(Data(repeating: 0xBB, count: 64))
        let r2Raw = HouseholdCBOR.encode(.map(r2FullMap))
        let r2 = VerifiedRevocation(
            mId: otherMember.mId, mPub: otherMember.mPub,
            machineCertFingerprint: otherMember.fingerprint,
            epoch: current.checkpoint.epoch, sequence: 2,
            prevEventHash: oracleRev.eventHash,
            revokedAt: current.checkpoint.issuedAt,
            reason: 1, cascade: 0,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            rawCBOR: r2Raw, canonicalUnsigned: r2Canonical, eventHash: r2EventHash
        )
        let candidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: 2, eventHeadHash: r2EventHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: [], revocations: [r1Prime, r2],
            rawCBOR: diffSignature, canonicalUnsigned: oracleRev.canonicalUnsigned,
            checkpointHash: oracleRev.eventHash
        )
        let outcome = try RosterAuthorityVerifier.advanceState(
            current: current, candidate: candidate, effectiveNow: refreshIssuedAt
        )
        guard case .eventDivergence(.prefixMismatch(let idx)) = outcome, idx == 0 else {
            Issue.record("expected eventDivergence(.prefixMismatch(index: 0))"); return
        }
    }

    @Test func evaluateTerminalCheckpointForkAbsorbsDifferentCandidate() throws {
        let root = try rootKey()
        let rootPub = root.publicKey.compressedRepresentation
        let owner = try ownerKey()
        let ownerPub = owner.publicKey.compressedRepresentation
        let hhId = "hh_termcp"
        let ownerPId = try HouseholdIdentifiers.personIdentifier(for: ownerPub)
        let epoch = Data(repeating: 0xAA, count: 32)
        let issuedAt: UInt64 = 1000
        let notAfter: UInt64 = 1300

        let personCert = try certSigner([
            "v": .unsigned(1),
            "type": .text("person"),
            "hh_id": .text(hhId),
            "p_id": .text(ownerPId),
            "p_pub": .bytes(ownerPub),
            "display_name": .text("Owner"),
            "caveats": .array(validOwnerCaveats()),
            "not_before": .unsigned(issuedAt),
            "not_after": .null,
            "nonce": .bytes(Data(repeating: 0xDD, count: 16)),
            "issued_at": .unsigned(issuedAt),
            "issued_by": .text(hhId),
            "owner_auth_tier": .text("strong"),
            "owner_provenance": .text("ios-secure-enclave-owner"),
        ], with: root)
        let personCertFingerprint = Data(SHA256.hash(data: personCert))

        func makeCP(seq: UInt64, mesh: Data) throws -> VerifiedCheckpoint {
            var cpMap: [String: HouseholdCBORValue] = [
                "v": .unsigned(1),
                "kind": .text("household-machine-roster-checkpoint/v1"),
                "hh_id": .text(hhId),
                "epoch": .bytes(epoch),
                "checkpoint_sequence": .unsigned(seq),
                "prev_checkpoint_hash": .bytes(Data(repeating: 0, count: 32)),
                "event_sequence": .unsigned(0),
                "event_head_hash": .bytes(Data(repeating: 0, count: 32)),
                "mesh_log_digest": .bytes(mesh),
                "issued_at": .unsigned(issuedAt),
                "not_after": .unsigned(notAfter),
                "owner_p_id": .text(ownerPId),
                "owner_cert_fingerprint": .bytes(personCertFingerprint),
                "active": .array([]),
                "revocations": .array([]),
                "owner_person_cert": .bytes(personCert),
            ]
            let cpCBOR = try checkpointSigner(cpMap, with: owner)
            return try RosterAuthorityVerifier.verifyCheckpointRecord(
                canonicalCheckpoint: cpCBOR, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: issuedAt
            )
        }

        let cpA = try makeCP(seq: 1, mesh: Data(repeating: 0xAA, count: 32))
        let cpB = try makeCP(seq: 1, mesh: Data(repeating: 0xBB, count: 32))
        let genesisState = try RosterAuthorityVerifier.genesisState(from: cpA, effectiveNow: issuedAt)
        let forkResult = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(genesisState), candidate: cpB, effectiveNow: issuedAt
        )
        guard case .checkpointFork(let fork) = forkResult else {
            Issue.record("expected checkpointFork"); return
        }
        let cpC = try makeCP(seq: 2, mesh: Data(repeating: 0xCC, count: 32))
        let absorbed = try RosterAuthorityVerifier.evaluateRoster(
            state: .checkpointFork(fork), candidate: cpC, effectiveNow: issuedAt
        )
        guard case .checkpointFork = absorbed else {
            Issue.record("terminal checkpointFork must absorb (return unchanged) with any candidate"); return
        }
    }

    @Test func evaluateTerminalEventForkAbsorbsDifferentCandidate() throws {
        let json = try loadFixture()
        let (hhId, rootPub) = try rootIds(json)
        let genesisHex = try str(try dict(json, "genesis_checkpoint"), "canonical_hex")
        let refreshHex = try str(try dict(json, "refresh_checkpoint"), "canonical_hex")
        let genesisBytes = try hexData(genesisHex)
        let refreshBytes = try hexData(refreshHex)
        let genesisIssuedAt = try peekIssuedAt(genesisBytes)
        let refreshIssuedAt = try peekIssuedAt(refreshBytes)
        let genesis = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: genesisBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: genesisIssuedAt
        )
        let refresh = try RosterAuthorityVerifier.verifyCheckpointRecord(
            canonicalCheckpoint: refreshBytes, expectedHouseholdId: hhId, householdPublicKey: rootPub, effectiveNow: refreshIssuedAt
        )
        let genesisState = try RosterAuthorityVerifier.genesisState(from: genesis, effectiveNow: genesisIssuedAt)
        let advanced = try RosterAuthorityVerifier.advanceState(
            current: genesisState, candidate: refresh, effectiveNow: refreshIssuedAt
        )
        guard case .advanced(let current) = advanced else { Issue.record("expected advanced from oracle"); return }

        let basisMembers = current.basis.members
        let revokedMId = current.projection.tombstones[0].mId
        guard let otherMember = basisMembers.first(where: { $0.mId != revokedMId }) else {
            Issue.record("need at least 2 basis members"); return
        }

        let revMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(current.checkpoint.epoch),
            "sequence": .unsigned(1), "prev_event_hash": .bytes(RosterAuthorityVerifier.zeroHash32),
            "m_id": .text(otherMember.mId), "m_pub": .bytes(otherMember.mPub),
            "machine_cert_fingerprint": .bytes(otherMember.fingerprint),
            "revoked_at": .unsigned(current.checkpoint.issuedAt),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(current.checkpoint.ownerPId),
            "owner_cert_fingerprint": .bytes(current.checkpoint.ownerCertFingerprint),
        ]
        var revUnsignedMap: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { revUnsignedMap[key] = revMap[key] }
        let revCanonical = HouseholdCBOR.encode(.map(revUnsignedMap))
        let revEventHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: revCanonical)
        var revFullMap = revMap
        revFullMap["signature"] = .bytes(Data(repeating: 0xAA, count: 64))
        let revRaw = HouseholdCBOR.encode(.map(revFullMap))
        let rev = VerifiedRevocation(
            mId: otherMember.mId, mPub: otherMember.mPub,
            machineCertFingerprint: otherMember.fingerprint,
            epoch: current.checkpoint.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32,
            revokedAt: current.checkpoint.issuedAt,
            reason: 1, cascade: 0,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, eventHash: revEventHash
        )
        let expectedActive = basisMembers.filter { $0.mId != otherMember.mId }
        let eventCandidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: 1, eventHeadHash: revEventHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: expectedActive, revocations: [rev],
            rawCBOR: revRaw, canonicalUnsigned: revCanonical, checkpointHash: revEventHash
        )
        let forkResult = try RosterAuthorityVerifier.evaluateRoster(
            state: .accepted(current), candidate: eventCandidate, effectiveNow: refreshIssuedAt
        )
        guard case .eventFork(let ef) = forkResult else {
            Issue.record("expected eventFork"); return
        }
        let otherMap: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "kind": .text(RosterAuthorityVerifier.revocationKind),
            "hh_id": .text(hhId), "epoch": .bytes(current.checkpoint.epoch),
            "sequence": .unsigned(1), "prev_event_hash": .bytes(RosterAuthorityVerifier.zeroHash32),
            "m_id": .text(otherMember.mId), "m_pub": .bytes(otherMember.mPub),
            "machine_cert_fingerprint": .bytes(otherMember.fingerprint),
            "revoked_at": .unsigned(current.checkpoint.issuedAt + 1),
            "reason": .unsigned(1), "cascade": .unsigned(0),
            "owner_p_id": .text(current.checkpoint.ownerPId),
            "owner_cert_fingerprint": .bytes(current.checkpoint.ownerCertFingerprint),
        ]
        var otherUnsignedMap: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys { otherUnsignedMap[key] = otherMap[key] }
        let otherCanonical = HouseholdCBOR.encode(.map(otherUnsignedMap))
        let otherHash = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: otherCanonical)
        var otherFullMap = otherMap
        otherFullMap["signature"] = .bytes(Data(repeating: 0xBB, count: 64))
        let otherRaw = HouseholdCBOR.encode(.map(otherFullMap))
        let otherRev = VerifiedRevocation(
            mId: otherMember.mId, mPub: otherMember.mPub,
            machineCertFingerprint: otherMember.fingerprint,
            epoch: current.checkpoint.epoch, sequence: 1,
            prevEventHash: RosterAuthorityVerifier.zeroHash32,
            revokedAt: current.checkpoint.issuedAt + 1,
            reason: 1, cascade: 0,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            rawCBOR: otherRaw, canonicalUnsigned: otherCanonical, eventHash: otherHash
        )
        let diffCandidate = VerifiedCheckpoint(
            epoch: current.checkpoint.epoch,
            checkpointSequence: current.checkpoint.checkpointSequence + 1,
            prevCheckpointHash: current.checkpoint.checkpointHash,
            eventSequence: 1, eventHeadHash: otherHash,
            meshLogDigest: current.checkpoint.meshLogDigest,
            issuedAt: current.checkpoint.issuedAt,
            notAfter: current.checkpoint.notAfter,
            ownerPId: current.checkpoint.ownerPId,
            ownerCertFingerprint: current.checkpoint.ownerCertFingerprint,
            active: expectedActive, revocations: [otherRev],
            rawCBOR: otherRaw, canonicalUnsigned: otherCanonical, checkpointHash: otherHash
        )
        let absorbed = try RosterAuthorityVerifier.evaluateRoster(
            state: .eventFork(ef), candidate: diffCandidate, effectiveNow: refreshIssuedAt
        )
        guard case .eventFork = absorbed else {
            Issue.record("terminal eventFork must absorb (return unchanged) with any candidate"); return
        }
    }

    // MARK: - Domains

    @Test func domainsMatchOracle() throws {
        let json = try loadFixture()
        let domains = try dict(try dict(json, "b1_metadata"), "domains")
        #expect(try str(domains, "checkpoint") == "soyeht/household-machine-roster-checkpoint/v1\u{0}")
        #expect(try str(domains, "revocation") == "soyeht/household-machine-roster-revocation/v1\u{0}")
        #expect(RosterAuthorityVerifier.checkpointDomain == Data(try str(domains, "checkpoint").utf8))
        #expect(RosterAuthorityVerifier.revocationDomain == Data(try str(domains, "revocation").utf8))
    }

    @Test func checkpointHashOracleMatchesFixturePreimage() throws {
        let json = try loadFixture()
        let genesis = try dict(json, "genesis_checkpoint")
        let bytes = try hexData(try str(genesis, "canonical_hex"))
        guard case .map(let fullMap) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.checkpointUnsignedKeys {
            unsigned[key] = fullMap[key]
        }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        let computed = RosterAuthorityVerifier.checkpointHash(canonicalUnsigned: canonicalUnsigned)
        #expect(try computed == hexData(str(genesis, "hash_hex")))
        let preimage = try hexData(try str(genesis, "preimage_hex"))
        let domain = Data("soyeht/household-machine-roster-checkpoint/v1\u{0}".utf8)
        #expect(preimage == domain + canonicalUnsigned)
    }

    @Test func revocationEventHashOracleMatchesFixturePreimage() throws {
        let json = try loadFixture()
        let revDict = try dict(json, "revocation")
        let bytes = try hexData(try str(revDict, "canonical_hex"))
        guard case .map(let fullMap) = try HouseholdCBOR.decode(bytes) else {
            Issue.record("expected map"); return
        }
        var unsigned: [String: HouseholdCBORValue] = [:]
        for key in RosterAuthorityVerifier.revocationUnsignedKeys {
            unsigned[key] = fullMap[key]
        }
        let canonicalUnsigned = HouseholdCBOR.encode(.map(unsigned))
        let computed = RosterAuthorityVerifier.revocationEventHash(canonicalUnsigned: canonicalUnsigned)
        #expect(try computed == hexData(str(revDict, "event_hash_hex")))
        let preimage = try hexData(try str(revDict, "preimage_hex"))
        let domain = Data("soyeht/household-machine-roster-revocation/v1\u{0}".utf8)
        #expect(preimage == domain + canonicalUnsigned)
    }
}

private extension Data {
    func togglingLastBit() -> Data {
        guard !isEmpty else { return self }
        var result = self
        result[result.count - 1] ^= 0x01
        return result
    }
}
