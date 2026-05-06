import Foundation

public enum OperatorAuthorizationSignerError: Error, Equatable, Sendable {
    case householdMismatch
    case biometryCanceled
    case biometryLockout
    case signingFailed
}

/// The result of an owner-approval signing ceremony.
///
/// `signedContext` is the canonical CBOR `OwnerApprovalContext` bytes the
/// owner identity key actually signed; `outerBody` is the canonical CBOR
/// `OwnerApproval` payload to POST to `/owner-events/approve` (or `/decline`).
public struct OperatorAuthorizationResult: Equatable, Sendable {
    public let approvalSignature: Data       // 64-byte raw r||s
    public let outerBody: Data
    public let signedContext: Data
    public let cursor: UInt64
    public let timestamp: UInt64

    public init(
        approvalSignature: Data,
        outerBody: Data,
        signedContext: Data,
        cursor: UInt64,
        timestamp: UInt64
    ) {
        self.approvalSignature = approvalSignature
        self.outerBody = outerBody
        self.signedContext = signedContext
        self.cursor = cursor
        self.timestamp = timestamp
    }
}

public struct OperatorAuthorizationSigner: Sendable {
    public init() {}

    public func sign(
        envelope: JoinRequestEnvelope,
        cursor: UInt64,
        ownerIdentity: any OwnerIdentitySigning,
        localHouseholdId: String,
        now: Date = Date()
    ) throws -> OperatorAuthorizationResult {
        // FR-009: refuse to sign anything that doesn't claim the local household.
        guard envelope.householdId == localHouseholdId else {
            throw OperatorAuthorizationSignerError.householdMismatch
        }

        let timestamp = UInt64(now.timeIntervalSince1970)
        let signedContext = HouseholdCBOR.ownerApprovalContext(
            householdId: envelope.householdId,
            ownerPersonId: ownerIdentity.personId,
            cursor: cursor,
            challengeSignature: envelope.challengeSignature,
            timestamp: timestamp
        )

        let signature: Data
        do {
            signature = try ownerIdentity.sign(signedContext)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw OperatorAuthorizationSignerError.biometryCanceled
        } catch OwnerIdentityKeyError.biometryLockout {
            throw OperatorAuthorizationSignerError.biometryLockout
        } catch {
            throw OperatorAuthorizationSignerError.signingFailed
        }

        let outerBody = HouseholdCBOR.ownerApprovalBody(
            cursor: cursor,
            approvalSignature: signature
        )

        return OperatorAuthorizationResult(
            approvalSignature: signature,
            outerBody: outerBody,
            signedContext: signedContext,
            cursor: cursor,
            timestamp: timestamp
        )
    }
}
