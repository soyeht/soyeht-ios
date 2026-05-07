import CryptoKit
import Foundation
@testable import SoyehtCore

enum HouseholdTestFixtures {
    /// Generates a syntactically valid 33-byte compressed P-256 public
    /// key for fixture use. **The returned key may NOT be on the curve**
    /// when `prefix` is overridden — the function deterministically
    /// rewrites the leading byte to the requested 0x02/0x03 SEC1 sign
    /// marker without recomputing the underlying point. This is fine for
    /// any test that only needs a stable byte pattern with a valid
    /// SEC1 prefix (length checks, equality checks, identifier
    /// derivation via BLAKE3, etc.). It is NOT safe to feed this into
    /// `P256.Signing.PublicKey(compressedRepresentation:)` — that
    /// initializer enforces curve membership and will throw. If a test
    /// needs a real, on-curve public key, use
    /// `P256.Signing.PrivateKey(...).publicKey.compressedRepresentation`
    /// directly.
    static func publicKey(byte: UInt8 = 1, prefix: UInt8 = 0x02) -> Data {
        let privateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
        var publicKey = privateKey.publicKey.compressedRepresentation
        if publicKey.first != prefix {
            publicKey[publicKey.startIndex] = prefix
        }
        return publicKey
    }

    static func nonce(byte: UInt8 = 7) -> Data {
        Data(repeating: byte, count: 32)
    }

    static func signedOwnerCert(
        householdPrivateKey: P256.Signing.PrivateKey,
        personPublicKey: Data,
        householdId: String? = nil,
        operations: Set<String> = PersonCert.requiredOwnerOperations,
        scopeForOperation: ((String) -> HouseholdCBORValue?)? = nil,
        now: Date = Date(timeIntervalSince1970: 1_714_972_800)
    ) throws -> Data {
        let hhPub = householdPrivateKey.publicKey.compressedRepresentation
        let resolvedHouseholdId = try householdId ?? HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let personId = try HouseholdIdentifiers.personIdentifier(for: personPublicKey)
        let caveats = operations.sorted().map { op in
            HouseholdCBORValue.map([
                "constraints": .null,
                "op": .text(op),
                "scope": scopeForOperation?(op) ?? (op.hasPrefix("household.") ? .null : .map(["all": .bool(true)])),
            ])
        }
        let withoutSignature = HouseholdCBORValue.map([
            "caveats": .array(caveats),
            "display_name": .text("Caio"),
            "hh_id": .text(resolvedHouseholdId),
            "issued_at": .unsigned(UInt64(now.timeIntervalSince1970)),
            "issued_by": .text(resolvedHouseholdId),
            "nonce": .bytes(Data(repeating: 9, count: 16)),
            "not_after": .null,
            "not_before": .unsigned(UInt64(now.timeIntervalSince1970 - 60)),
            "p_id": .text(personId),
            "p_pub": .bytes(personPublicKey),
            "type": .text("person"),
            "v": .unsigned(1),
        ])
        let signingBytes = HouseholdCBOR.encode(withoutSignature)
        let signature = try householdPrivateKey.signature(for: signingBytes).rawRepresentation

        guard case .map(var map) = withoutSignature else { fatalError("fixture map expected") }
        map["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(map))
    }

    /// Builds a canonical-CBOR-encoded `MachineCert` per protocol §5, signed
    /// by `householdPrivateKey`. Pass an `overrides` map to mutate any field
    /// before encoding (used to construct adversarial fixtures).
    static func signedMachineCert(
        householdPrivateKey: P256.Signing.PrivateKey,
        machinePublicKey: Data,
        householdId: String? = nil,
        hostname: String = "studio.local",
        platform: String = "macos",
        joinedAt: Date = Date(timeIntervalSince1970: 1_714_972_800),
        overrides: [String: HouseholdCBORValue] = [:]
    ) throws -> Data {
        let hhPub = householdPrivateKey.publicKey.compressedRepresentation
        let resolvedHouseholdId = try householdId ?? HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let machineId = try HouseholdIdentifiers.identifier(for: machinePublicKey, kind: .machine)
        var withoutSignatureMap: [String: HouseholdCBORValue] = [
            "hh_id": .text(resolvedHouseholdId),
            "hostname": .text(hostname),
            "issued_by": .text(resolvedHouseholdId),
            "joined_at": .unsigned(UInt64(joinedAt.timeIntervalSince1970)),
            "m_id": .text(machineId),
            "m_pub": .bytes(machinePublicKey),
            "platform": .text(platform),
            "type": .text("machine"),
            "v": .unsigned(1),
        ]
        for (key, value) in overrides where key != "signature" {
            withoutSignatureMap[key] = value
        }
        let signingBytes = HouseholdCBOR.encode(.map(withoutSignatureMap))
        let signature: Data
        if let overrideSignature = overrides["signature"], case .bytes(let bytes) = overrideSignature {
            signature = bytes
        } else {
            signature = try householdPrivateKey.signature(for: signingBytes).rawRepresentation
        }
        var fullMap = withoutSignatureMap
        fullMap["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(fullMap))
    }
}
