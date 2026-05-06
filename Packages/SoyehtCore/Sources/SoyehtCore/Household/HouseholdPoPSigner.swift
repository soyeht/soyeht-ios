import Foundation

public enum HouseholdPoPError: Error, Equatable {
    case noActiveHousehold
    case invalidLocalCert
    case missingCaveat(String)
    case ownerIdentityUnavailable
    case biometryCanceled
    case signingFailed
}

public struct ProofOfPossessionAuthorization: Equatable, Sendable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: UInt64
    public let bodyHash: Data
    public let signingContext: Data
    public let signature: Data
    public let authorizationHeader: String

    public init(
        method: String,
        pathAndQuery: String,
        timestamp: UInt64,
        bodyHash: Data,
        signingContext: Data,
        signature: Data,
        authorizationHeader: String
    ) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.bodyHash = bodyHash
        self.signingContext = signingContext
        self.signature = signature
        self.authorizationHeader = authorizationHeader
    }
}

public struct HouseholdPoPSigner {
    private let ownerIdentity: any OwnerIdentitySigning
    private let now: @Sendable () -> Date

    public init(
        ownerIdentity: any OwnerIdentitySigning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ownerIdentity = ownerIdentity
        self.now = now
    }

    public func authorization(
        method: String,
        pathAndQuery: String,
        body: Data = Data()
    ) throws -> ProofOfPossessionAuthorization {
        let normalizedMethod = method.uppercased()
        let timestamp = UInt64(max(0, now().timeIntervalSince1970))
        let bodyHash = HouseholdHash.blake3(body)
        let signingContext = HouseholdCBOR.requestSigningContext(
            method: normalizedMethod,
            pathAndQuery: pathAndQuery,
            timestamp: timestamp,
            bodyHash: bodyHash
        )
        let signature: Data
        do {
            signature = try ownerIdentity.sign(signingContext)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPoPError.biometryCanceled
        } catch {
            throw HouseholdPoPError.signingFailed
        }
        let header = "Soyeht-PoP v1:\(ownerIdentity.personId):\(timestamp):\(signature.soyehtBase64URLEncodedString())"
        return ProofOfPossessionAuthorization(
            method: normalizedMethod,
            pathAndQuery: pathAndQuery,
            timestamp: timestamp,
            bodyHash: bodyHash,
            signingContext: signingContext,
            signature: signature,
            authorizationHeader: header
        )
    }
}
