import CryptoKit
import Foundation

public enum MobileClawVPNDevE2EExecutionTupleError: Error, Equatable {
    case malformedCBOR
    case nonCanonicalCBOR
    case invalidShape
}

/// Canonical, versioned tuple committed by the DEV-only mobile Claw VPN owner
/// approval operation. This is a data contract only: it does not start a
/// WebAuthn ceremony, mint a capability, or authorize an endpoint.
public struct MobileClawVPNDevE2EExecutionTupleV1: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let purpose = "mobile-claw-vpn-dev-e2e-execution"
    public static let operation = OwnerApprovalOperation.mobileClawVPNDevE2EExecute
    public static let executionDomain =
        Data("soyeht-mobile-claw-vpn-dev-e2e-execution-v1".utf8) + Data([0])
    public static let bundleID = "com.soyeht.app.dev"
    public static let capability = "mobile-claw-vpn-dev-e2e-execute"
    public static let maximumApprovalTTL: UInt64 = 120

    public var version: UInt8
    public var purpose: String
    public var op: OwnerApprovalOperation
    public var householdID: String
    public var engineAudience: Data
    public var memberID: String
    public var attemptID: String
    public var readinessRunID: String
    public var sourceArtifactGitSHA1: Data
    public var executionManifestSHA256: Data
    /// Tooling correlation claim, not a device attestation by itself.
    public var deviceBinding: Data
    public var executionRunID: String
    /// Executor claim digest, not an authority by itself.
    public var executionClaimSHA256: Data
    public var bundleID: String
    public var deviceID: String
    public var clawID: String
    public var deviceAlias: String
    public var clawAlias: String
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var serverNonce: Data

    public init(
        householdID: String,
        engineAudience: Data,
        memberID: String,
        attemptID: String,
        readinessRunID: String,
        sourceArtifactGitSHA1: Data,
        executionManifestSHA256: Data,
        deviceBinding: Data,
        executionRunID: String,
        executionClaimSHA256: Data,
        deviceID: String,
        clawID: String,
        deviceAlias: String,
        clawAlias: String,
        issuedAt: UInt64,
        expiresAt: UInt64,
        serverNonce: Data
    ) {
        version = Self.currentVersion
        purpose = Self.purpose
        op = Self.operation
        self.householdID = householdID
        self.engineAudience = engineAudience
        self.memberID = memberID
        self.attemptID = attemptID
        self.readinessRunID = readinessRunID
        self.sourceArtifactGitSHA1 = sourceArtifactGitSHA1
        self.executionManifestSHA256 = executionManifestSHA256
        self.deviceBinding = deviceBinding
        self.executionRunID = executionRunID
        self.executionClaimSHA256 = executionClaimSHA256
        bundleID = Self.bundleID
        self.deviceID = deviceID
        self.clawID = clawID
        self.deviceAlias = deviceAlias
        self.clawAlias = clawAlias
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.serverNonce = serverNonce
    }

    public func validateShape() throws {
        guard version == Self.currentVersion,
              purpose == Self.purpose,
              op == Self.operation,
              Self.isCanonicalHouseholdID(householdID),
              engineAudience.count == 32,
              Self.isASCIIIdentifier(memberID),
              Self.isCanonicalUUID(attemptID),
              Self.isCanonicalUUID(readinessRunID),
              sourceArtifactGitSHA1.count == 20,
              executionManifestSHA256.count == 32,
              deviceBinding.count == 32,
              Self.isCanonicalUUID(executionRunID),
              executionClaimSHA256.count == 32,
              bundleID == Self.bundleID,
              Self.isASCIIIdentifier(deviceID),
              Self.isASCIIIdentifier(clawID),
              deviceAlias == "Device-D",
              ["Claw-M", "Claw-L"].contains(clawAlias),
              expiresAt > issuedAt,
              expiresAt - issuedAt <= Self.maximumApprovalTTL,
              serverNonce.count == 32 else {
            throw MobileClawVPNDevE2EExecutionTupleError.invalidShape
        }
    }

    public func cborValue() -> HouseholdCBORValue {
        .map([
            "v": .unsigned(UInt64(version)),
            "purpose": .text(purpose),
            "op": .text(op.rawValue),
            "hh_id": .text(householdID),
            "engine_audience": .bytes(engineAudience),
            "member_id": .text(memberID),
            "attempt_id": .text(attemptID),
            "readiness_run_id": .text(readinessRunID),
            "source_artifact_git_sha1": .bytes(sourceArtifactGitSHA1),
            "execution_manifest_sha256": .bytes(executionManifestSHA256),
            "device_binding": .bytes(deviceBinding),
            "execution_run_id": .text(executionRunID),
            "execution_claim_sha256": .bytes(executionClaimSHA256),
            "bundle_id": .text(bundleID),
            "device_id": .text(deviceID),
            "claw_id": .text(clawID),
            "device_alias": .text(deviceAlias),
            "claw_alias": .text(clawAlias),
            "issued_at": .unsigned(issuedAt),
            "expires_at": .unsigned(expiresAt),
            "server_nonce": .bytes(serverNonce),
        ])
    }

    public func canonicalBytes() throws -> Data {
        try validateShape()
        return HouseholdCBOR.encode(cborValue())
    }

    public func executionHash() throws -> Data {
        var material = Self.executionDomain
        material.append(try canonicalBytes())
        return Data(SHA256.hash(data: material))
    }

    public init(canonicalBytes: Data) throws {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(canonicalBytes)
        } catch {
            throw MobileClawVPNDevE2EExecutionTupleError.malformedCBOR
        }
        try self.init(cbor: value)
        guard try self.canonicalBytes() == canonicalBytes else {
            throw MobileClawVPNDevE2EExecutionTupleError.nonCanonicalCBOR
        }
    }

    public init(cbor: HouseholdCBORValue) throws {
        guard case .map(let map) = cbor,
              Set(map.keys) == Self.expectedKeys,
              case .unsigned(let rawVersion)? = map["v"],
              let version = UInt8(exactly: rawVersion),
              case .text(let purpose)? = map["purpose"],
              case .text(let rawOperation)? = map["op"],
              let operation = OwnerApprovalOperation(rawValue: rawOperation),
              case .text(let householdID)? = map["hh_id"],
              case .bytes(let engineAudience)? = map["engine_audience"],
              case .text(let memberID)? = map["member_id"],
              case .text(let attemptID)? = map["attempt_id"],
              case .text(let readinessRunID)? = map["readiness_run_id"],
              case .bytes(let sourceArtifactGitSHA1)? = map["source_artifact_git_sha1"],
              case .bytes(let executionManifestSHA256)? = map["execution_manifest_sha256"],
              case .bytes(let deviceBinding)? = map["device_binding"],
              case .text(let executionRunID)? = map["execution_run_id"],
              case .bytes(let executionClaimSHA256)? = map["execution_claim_sha256"],
              case .text(let bundleID)? = map["bundle_id"],
              case .text(let deviceID)? = map["device_id"],
              case .text(let clawID)? = map["claw_id"],
              case .text(let deviceAlias)? = map["device_alias"],
              case .text(let clawAlias)? = map["claw_alias"],
              case .unsigned(let issuedAt)? = map["issued_at"],
              case .unsigned(let expiresAt)? = map["expires_at"],
              case .bytes(let serverNonce)? = map["server_nonce"] else {
            throw MobileClawVPNDevE2EExecutionTupleError.malformedCBOR
        }

        self.version = version
        self.purpose = purpose
        op = operation
        self.householdID = householdID
        self.engineAudience = engineAudience
        self.memberID = memberID
        self.attemptID = attemptID
        self.readinessRunID = readinessRunID
        self.sourceArtifactGitSHA1 = sourceArtifactGitSHA1
        self.executionManifestSHA256 = executionManifestSHA256
        self.deviceBinding = deviceBinding
        self.executionRunID = executionRunID
        self.executionClaimSHA256 = executionClaimSHA256
        self.bundleID = bundleID
        self.deviceID = deviceID
        self.clawID = clawID
        self.deviceAlias = deviceAlias
        self.clawAlias = clawAlias
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.serverNonce = serverNonce
        try validateShape()
    }

    private static let expectedKeys: Set<String> = [
        "v", "purpose", "op", "hh_id", "engine_audience", "member_id",
        "attempt_id", "readiness_run_id", "source_artifact_git_sha1",
        "execution_manifest_sha256", "device_binding", "execution_run_id",
        "execution_claim_sha256", "bundle_id", "device_id", "claw_id",
        "device_alias", "claw_alias", "issued_at", "expires_at", "server_nonce",
    ]

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.lowercased() == value
    }

    private static func isCanonicalHouseholdID(_ value: String) -> Bool {
        guard value.hasPrefix("hh_") else { return false }
        let suffix = value.dropFirst(3)
        return suffix.utf8.count == HouseholdIdentifiers.base32EncodedBLAKE3DigestLength
            && suffix.utf8.allSatisfy { (0x61 ... 0x7a).contains($0) || (0x32 ... 0x37).contains($0) }
    }

    private static func isASCIIIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty
            && bytes.count <= 512
            && bytes.allSatisfy { (0x21 ... 0x7e).contains($0) }
    }
}

extension MobileClawVPNDevE2EExecutionTupleV1:
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public var description: String {
        "MobileClawVPNDevE2EExecutionTupleV1(redacted: true)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}
