import CryptoKit
import Foundation

public enum SecureUpgradeTranscriptError: Error, Equatable {
    case invalidShape(String)
}

public enum SecureUpgradeCommitmentError: Error, Equatable {
    case clientDataHashMismatch
    case ownerSignatureInputMismatch
}

public enum SecureUpgradeOperation: String, Sendable {
    case secureUpgradeWithIphone = "secure-upgrade-with-iphone"
}

public enum SecureUpgradeProofModel: String, Sendable {
    case appAttest = "app-attest"
}

public enum SecureUpgradeProofEnvironment: String, Sendable {
    case development
    case production
}

public enum SecureUpgradePlatform: String, Sendable {
    case ios
    case ipados

    public var appAttestProvenance: String {
        switch self {
        case .ios:
            "ios-app-attest-owner"
        case .ipados:
            "ipados-app-attest-owner"
        }
    }
}

public struct SecureUpgradeProofCommitments: Sendable, Equatable {
    public var clientDataHash: Data
    public var ownerSignatureInput: Data

    public init(clientDataHash: Data, ownerSignatureInput: Data) {
        self.clientDataHash = clientDataHash
        self.ownerSignatureInput = ownerSignatureInput
    }
}

public struct SecureUpgradeCommitmentVerification: Sendable, Equatable {
    public var challengeDigest: Data

    public init(challengeDigest: Data) {
        self.challengeDigest = challengeDigest
    }
}

public struct SecureUpgradeTranscript: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let purpose = "secure-upgrade-owner"
    public static let challengeDomain = Data("soyeht-secure-upgrade-v1\u{0}".utf8)

    public var version: UInt8
    public var purpose: String
    public var operation: SecureUpgradeOperation
    public var householdID: String
    public var ownerPersonID: String
    public var ownerKeyID: String
    public var challengeID: String
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var appTeamID: String
    public var appBundleID: String
    public var proofModel: SecureUpgradeProofModel
    public var proofKeyID: String
    public var proofEnvironment: SecureUpgradeProofEnvironment
    public var platform: SecureUpgradePlatform
    public var targetProvenance: String

    public init(
        version: UInt8 = SecureUpgradeTranscript.currentVersion,
        purpose: String = SecureUpgradeTranscript.purpose,
        operation: SecureUpgradeOperation = .secureUpgradeWithIphone,
        householdID: String,
        ownerPersonID: String,
        ownerKeyID: String,
        challengeID: String,
        issuedAt: UInt64,
        expiresAt: UInt64,
        appTeamID: String,
        appBundleID: String,
        proofModel: SecureUpgradeProofModel = .appAttest,
        proofKeyID: String,
        proofEnvironment: SecureUpgradeProofEnvironment,
        platform: SecureUpgradePlatform,
        targetProvenance: String? = nil
    ) {
        self.version = version
        self.purpose = purpose
        self.operation = operation
        self.householdID = householdID
        self.ownerPersonID = ownerPersonID
        self.ownerKeyID = ownerKeyID
        self.challengeID = challengeID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.appTeamID = appTeamID
        self.appBundleID = appBundleID
        self.proofModel = proofModel
        self.proofKeyID = proofKeyID
        self.proofEnvironment = proofEnvironment
        self.platform = platform
        self.targetProvenance = targetProvenance ?? platform.appAttestProvenance
    }

    public func validateShape() throws {
        guard version == Self.currentVersion else {
            throw SecureUpgradeTranscriptError.invalidShape("unsupported version")
        }
        guard purpose == Self.purpose else {
            throw SecureUpgradeTranscriptError.invalidShape("purpose mismatch")
        }
        guard expiresAt >= issuedAt else {
            throw SecureUpgradeTranscriptError.invalidShape("expires before issued")
        }
        for (field, value) in [
            ("owner_key_id", ownerKeyID),
            ("challenge_id", challengeID),
            ("app_team_id", appTeamID),
            ("app_bundle_id", appBundleID),
            ("proof_key_id", proofKeyID),
        ] where value.isEmpty {
            throw SecureUpgradeTranscriptError.invalidShape("\(field) empty")
        }
        guard proofModel == .appAttest else {
            throw SecureUpgradeTranscriptError.invalidShape("unsupported proof model")
        }
        guard targetProvenance == platform.appAttestProvenance else {
            throw SecureUpgradeTranscriptError.invalidShape("target provenance does not match platform")
        }
    }

    public func cborValue() -> HouseholdCBORValue {
        .map([
            "v": .unsigned(UInt64(version)),
            "purpose": .text(purpose),
            "op": .text(operation.rawValue),
            "hh_id": .text(householdID),
            "owner_p_id": .text(ownerPersonID),
            "owner_key_id": .text(ownerKeyID),
            "challenge_id": .text(challengeID),
            "issued_at": .unsigned(issuedAt),
            "expires_at": .unsigned(expiresAt),
            "app_team_id": .text(appTeamID),
            "app_bundle_id": .text(appBundleID),
            "proof_model": .text(proofModel.rawValue),
            "proof_key_id": .text(proofKeyID),
            "proof_environment": .text(proofEnvironment.rawValue),
            "platform": .text(platform.rawValue),
            "target_provenance": .text(targetProvenance),
        ])
    }

    public func canonicalBytes() throws -> Data {
        try validateShape()
        return HouseholdCBOR.encode(cborValue())
    }

    public static func challengeDigest(canonicalTranscriptBytes: Data) -> Data {
        var bytes = challengeDomain
        bytes.append(canonicalTranscriptBytes)
        return Data(SHA256.hash(data: bytes))
    }

    public func challengeDigest() throws -> Data {
        Self.challengeDigest(canonicalTranscriptBytes: try canonicalBytes())
    }

    public func appAttestClientDataHash() throws -> Data {
        try challengeDigest()
    }

    public func ownerSignatureInput() throws -> Data {
        try challengeDigest()
    }

    public static func verifyProofCommitments(
        canonicalTranscriptBytes: Data,
        commitments: SecureUpgradeProofCommitments
    ) throws -> SecureUpgradeCommitmentVerification {
        let expectedDigest = challengeDigest(canonicalTranscriptBytes: canonicalTranscriptBytes)
        guard commitments.clientDataHash == expectedDigest else {
            throw SecureUpgradeCommitmentError.clientDataHashMismatch
        }
        guard commitments.ownerSignatureInput == expectedDigest else {
            throw SecureUpgradeCommitmentError.ownerSignatureInputMismatch
        }
        return SecureUpgradeCommitmentVerification(challengeDigest: expectedDigest)
    }
}
