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
}

// MARK: - Owner approval context (Protocol v2)

/// Canonical CBOR context an owner signs (via a passkey assertion) to approve a
/// privileged household operation under approval Protocol v2.
///
/// This is the security-critical half of the v2 envelope: the WebAuthn challenge
/// the platform authenticator signs is `SHA256(domain || canonicalBytes())`, so
/// the Swift canonical CBOR MUST match the Rust producer byte-for-byte — a single
/// byte of drift silently rejects an otherwise-valid approval. Parity is pinned
/// by the cross-language golden vectors (`owner_approval_v2_vectors.json`).
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
        self.capabilities = capabilities
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.replayNonce = replayNonce
    }

    /// The CBOR value tree for this context. Optional fields are OMITTED (never
    /// encoded as null) to match the Rust `skip_serializing_if`.
    public func cborValue() -> HouseholdCBORValue {
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
        return .map(map)
    }

    /// Canonical (key-sorted, deterministic) CBOR encoding of the context.
    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue())
    }

    /// The WebAuthn challenge bound to this context:
    /// `SHA256(challengeDomain || canonicalBytes())`. This is the value the
    /// platform authenticator signs during the approval assertion ceremony.
    public func challengeDigest() -> Data {
        var material = Self.challengeDomain
        material.append(canonicalBytes())
        return Data(SHA256.hash(data: material))
    }
}
