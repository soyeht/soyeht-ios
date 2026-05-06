import CryptoKit
import Foundation
@testable import SoyehtCore

enum HouseholdTestFixtures {
    static func publicKey(byte: UInt8 = 1, prefix: UInt8 = 0x02) -> Data {
        Data([prefix]) + Data(repeating: byte, count: 32)
    }

    static func nonce(byte: UInt8 = 7) -> Data {
        Data(repeating: byte, count: 32)
    }

    static func signedOwnerCert(
        householdPrivateKey: P256.Signing.PrivateKey,
        personPublicKey: Data,
        householdId: String? = nil,
        operations: Set<String> = PersonCert.requiredOwnerOperations,
        now: Date = Date(timeIntervalSince1970: 1_714_972_800)
    ) throws -> Data {
        let hhPub = householdPrivateKey.publicKey.compressedRepresentation
        let resolvedHouseholdId = try householdId ?? HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let personId = try HouseholdIdentifiers.personIdentifier(for: personPublicKey)
        let caveats = operations.sorted().map { op in
            HouseholdCBORValue.map([
                "constraints": .null,
                "op": .text(op),
                "scope": op.hasPrefix("household.") ? .null : .map(["all": .bool(true)]),
            ])
        }
        let withoutSignature = HouseholdCBORValue.map([
            "caveats": .array(caveats),
            "display_name": .text("Caio"),
            "hh_id": .text(resolvedHouseholdId),
            "issued_at": .unsigned(UInt64(now.timeIntervalSince1970)),
            "issued_by": .text("hh:\(resolvedHouseholdId)"),
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
}
