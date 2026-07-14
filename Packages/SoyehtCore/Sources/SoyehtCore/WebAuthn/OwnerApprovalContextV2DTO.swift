import CryptoKit
import Foundation

// MARK: - Owner approval operation

/// The operation an owner approval-v2 context authorizes.
///
/// Wire form is kebab-case text, pinned to the Rust `OwnerOperation`
/// (`household-rs/src/owner_approval_v2.rs`, `#[serde(rename_all = "kebab-case")]`).
public enum OwnerApprovalOperation: String, Sendable, Equatable, CaseIterable {
    case pairMachineApprove = "pair-machine-approve"
    case bootstrapInitialize = "bootstrap-initialize"
    case bootstrapTeardown = "bootstrap-teardown"
    case pairDeviceConfirm = "pair-device-confirm"
    case revokeCredential = "revoke-credential"
    case addCredential = "add-credential"
    case mobileClawVPNDevE2EExecute = "mobile-claw-vpn-dev-e2e-execute"
}

// MARK: - Owner approval context (Protocol v2)

/// Canonical CBOR context an owner approves via a passkey assertion under
/// approval Protocol v2.
///
/// The WebAuthn challenge is an independent random RP nonce. The server binds
/// that challenge to its stored canonical context and requires the submitted
/// context to match exactly at finish. Swift canonical CBOR therefore MUST match
/// the Rust producer byte-for-byte. Parity is pinned by the cross-language
/// golden vectors (`owner_approval_v2_vectors.json`).
///
/// Field set + ordering + optional-skip rules mirror the Rust
/// `OwnerApprovalContextV2` struct (`#[serde(deny_unknown_fields)]`, optional
/// fields `skip_serializing_if = "Option::is_none"`). Canonical key ordering is
/// applied by `HouseholdCBOR.encode`.
public struct OwnerApprovalContextV2: Sendable, Equatable {
    /// Current protocol version (`v` == 2).
    public static let currentVersion: UInt8 = 2
    /// Fixed `purpose` discriminator.
    public static let purpose = "owner-approval-v2"
    /// Domain-separation prefix for the WebAuthn challenge digest
    /// (`b"soyeht-owner-approval-v2\0"`).
    public static let challengeDomain = Data("soyeht-owner-approval-v2".utf8) + Data([0])

    public var version: UInt8
    public var purpose: String
    public var op: OwnerApprovalOperation
    public var householdID: String
    public var ownerPersonID: String
    public var cursor: UInt64?
    public var machineID: String?
    public var addr: String?
    public var transport: String?
    public var ttlUnix: UInt64?
    public var nonce: Data?
    public var joinRequestHash: Data?
    public var newCredentialBindingHash: Data?
    public var authorityHeadSequence: UInt64?
    public var authorityHeadHash: Data?
    public var preActiveCredentialCount: UInt64?
    /// Required only by the DEV mobile execution operation. Owner approval-v2
    /// signs the canonical context containing this tuple hash.
    public var mobileClawVPNExecutionHash: Data?
    public var capabilities: [String]
    public var issuedAt: UInt64
    public var expiresAt: UInt64
    public var replayNonce: Data

    public init(
        version: UInt8 = OwnerApprovalContextV2.currentVersion,
        purpose: String = OwnerApprovalContextV2.purpose,
        op: OwnerApprovalOperation,
        householdID: String,
        ownerPersonID: String,
        cursor: UInt64? = nil,
        machineID: String? = nil,
        addr: String? = nil,
        transport: String? = nil,
        ttlUnix: UInt64? = nil,
        nonce: Data? = nil,
        joinRequestHash: Data? = nil,
        newCredentialBindingHash: Data? = nil,
        authorityHeadSequence: UInt64? = nil,
        authorityHeadHash: Data? = nil,
        preActiveCredentialCount: UInt64? = nil,
        mobileClawVPNExecutionHash: Data? = nil,
        capabilities: [String],
        issuedAt: UInt64,
        expiresAt: UInt64,
        replayNonce: Data
    ) {
        self.version = version
        self.purpose = purpose
        self.op = op
        self.householdID = householdID
        self.ownerPersonID = ownerPersonID
        self.cursor = cursor
        self.machineID = machineID
        self.addr = addr
        self.transport = transport
        self.ttlUnix = ttlUnix
        self.nonce = nonce
        self.joinRequestHash = joinRequestHash
        self.newCredentialBindingHash = newCredentialBindingHash
        self.authorityHeadSequence = authorityHeadSequence
        self.authorityHeadHash = authorityHeadHash
        self.preActiveCredentialCount = preActiveCredentialCount
        self.mobileClawVPNExecutionHash = mobileClawVPNExecutionHash
        self.capabilities = capabilities
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.replayNonce = replayNonce
    }

    /// The CBOR value tree for this context. Optional fields are OMITTED (never
    /// encoded as null) to match the Rust `skip_serializing_if`.
    public func cborValue() throws -> HouseholdCBORValue {
        try validateMobileClawVPNOperationShape()
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(UInt64(version)),
            "purpose": .text(purpose),
            "op": .text(op.rawValue),
            "hh_id": .text(householdID),
            "owner_p_id": .text(ownerPersonID),
            "capabilities": .array(capabilities.map(HouseholdCBORValue.text)),
            "issued_at": .unsigned(issuedAt),
            "expires_at": .unsigned(expiresAt),
            "replay_nonce": .bytes(replayNonce),
        ]
        if let cursor { map["cursor"] = .unsigned(cursor) }
        if let machineID { map["m_id"] = .text(machineID) }
        if let addr { map["addr"] = .text(addr) }
        if let transport { map["transport"] = .text(transport) }
        if let ttlUnix { map["ttl_unix"] = .unsigned(ttlUnix) }
        if let nonce { map["nonce"] = .bytes(nonce) }
        if let joinRequestHash { map["join_request_hash"] = .bytes(joinRequestHash) }
        if let newCredentialBindingHash {
            map["new_credential_binding_hash"] = .bytes(newCredentialBindingHash)
        }
        if let authorityHeadSequence {
            map["authority_head_sequence"] = .unsigned(authorityHeadSequence)
        }
        if let authorityHeadHash { map["authority_head_hash"] = .bytes(authorityHeadHash) }
        if let preActiveCredentialCount {
            map["pre_active_credential_count"] = .unsigned(preActiveCredentialCount)
        }
        if let mobileClawVPNExecutionHash {
            map["mobile_claw_vpn_execution_hash"] = .bytes(mobileClawVPNExecutionHash)
        }
        return .map(map)
    }

    /// Construct the inert signed context for the DEV-only mobile Claw VPN
    /// operation. The execution hash is always derived from the validated tuple;
    /// callers cannot supply an unrelated hash to this constructor.
    public static func mobileClawVPNDevE2EExecute(
        ownerPersonID: String,
        execution: MobileClawVPNDevE2EExecutionTupleV1,
        replayNonce: Data
    ) throws -> OwnerApprovalContextV2 {
        let context = OwnerApprovalContextV2(
            op: .mobileClawVPNDevE2EExecute,
            householdID: execution.householdID,
            ownerPersonID: ownerPersonID,
            mobileClawVPNExecutionHash: try execution.executionHash(),
            capabilities: [MobileClawVPNDevE2EExecutionTupleV1.capability],
            issuedAt: execution.issuedAt,
            expiresAt: execution.expiresAt,
            replayNonce: replayNonce
        )
        try context.validateMobileClawVPNOperationShape()
        return context
    }

    func validateMobileClawVPNOperationShape() throws {
        if op == .mobileClawVPNDevE2EExecute {
            guard version == Self.currentVersion,
                  purpose == Self.purpose,
                  Self.isCanonicalHouseholdID(householdID),
                  Self.isCanonicalPersonID(ownerPersonID),
                  cursor == nil,
                  machineID == nil,
                  addr == nil,
                  transport == nil,
                  ttlUnix == nil,
                  nonce == nil,
                  joinRequestHash == nil,
                  newCredentialBindingHash == nil,
                  authorityHeadSequence == nil,
                  authorityHeadHash == nil,
                  preActiveCredentialCount == nil,
                  mobileClawVPNExecutionHash?.count == 32,
                  capabilities == [MobileClawVPNDevE2EExecutionTupleV1.capability],
                  expiresAt > issuedAt,
                  expiresAt - issuedAt <= MobileClawVPNDevE2EExecutionTupleV1.maximumApprovalTTL,
                  replayNonce.count == 32 else {
                throw OwnerApprovalV2DTOError.malformedCBOR(
                    "context: invalid mobile Claw VPN execution binding"
                )
            }
        } else if mobileClawVPNExecutionHash != nil {
            throw OwnerApprovalV2DTOError.malformedCBOR(
                "context: mobile Claw VPN execution hash is not allowed for this operation"
            )
        }
    }

    private static func isCanonicalHouseholdID(_ value: String) -> Bool {
        guard value.hasPrefix("hh_") else { return false }
        let suffix = value.dropFirst(3)
        return suffix.utf8.count == HouseholdIdentifiers.base32EncodedBLAKE3DigestLength
            && suffix.utf8.allSatisfy { (0x61 ... 0x7a).contains($0) || (0x32 ... 0x37).contains($0) }
    }

    private static func isCanonicalPersonID(_ value: String) -> Bool {
        value.hasPrefix("p_") && value.utf8.count > 2
    }

    /// Canonical (key-sorted, deterministic) CBOR encoding of the context.
    public func canonicalBytes() throws -> Data {
        HouseholdCBOR.encode(try cborValue())
    }

    /// Deterministic context-binding digest:
    /// `SHA256(challengeDomain || canonicalBytes())`.
    ///
    /// This is not the WebAuthn challenge. The RP issues a separate random
    /// challenge and binds it server-side to the stored canonical context.
    public func challengeDigest() throws -> Data {
        var material = Self.challengeDomain
        material.append(try canonicalBytes())
        return Data(SHA256.hash(data: material))
    }
}
