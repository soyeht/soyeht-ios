import Foundation

public struct PairDeviceConfirmRequest: Codable, Equatable, Sendable {
    public let v: Int
    public let nonce: String
    public let pPub: String
    public let displayName: String
    public let proofSig: String

    enum CodingKeys: String, CodingKey {
        case v
        case nonce
        case pPub = "p_pub"
        case displayName = "display_name"
        case proofSig = "proof_sig"
    }

    public init(v: Int, nonce: String, pPub: String, displayName: String, proofSig: String) {
        self.v = v
        self.nonce = nonce
        self.pPub = pPub
        self.displayName = displayName
        self.proofSig = proofSig
    }
}

public enum PairingProof {
    public static func confirmRequest(
        qr: PairDeviceQR,
        ownerIdentity: any OwnerIdentitySigning,
        displayName: String = "Caio"
    ) throws -> PairDeviceConfirmRequest {
        let proofContext = HouseholdCBOR.pairingProofContext(
            householdId: qr.householdId,
            nonce: qr.nonce,
            personPublicKey: ownerIdentity.publicKey
        )
        let signature = try ownerIdentity.sign(proofContext)
        return PairDeviceConfirmRequest(
            v: 1,
            nonce: qr.nonce.soyehtBase64URLEncodedString(),
            pPub: ownerIdentity.publicKey.soyehtBase64URLEncodedString(),
            displayName: displayName,
            proofSig: signature.soyehtBase64URLEncodedString()
        )
    }
}
