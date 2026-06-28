import Foundation

// MARK: - Errors

/// A decode/shape failure for an owner approval-v2 wire value.
public enum OwnerApprovalV2DTOError: Error, Equatable, CustomStringConvertible {
    case malformedCBOR(String)

    public var description: String {
        switch self {
        case let .malformedCBOR(detail):
            return "OwnerApprovalV2 wire: \(detail)"
        }
    }
}

// MARK: - CBOR accessors (file-private, mirror the registration DTO idiom)

private extension HouseholdCBORValue {
    func cborMap(_ context: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = self else {
            throw OwnerApprovalV2DTOError.malformedCBOR("\(context): expected map")
        }
        return map
    }

    func cborText(_ context: String) throws -> String {
        guard case .text(let text) = self else {
            throw OwnerApprovalV2DTOError.malformedCBOR("\(context): expected text string")
        }
        return text
    }

    func cborBytes(_ context: String) throws -> Data {
        guard case .bytes(let bytes) = self else {
            throw OwnerApprovalV2DTOError.malformedCBOR("\(context): expected byte string")
        }
        return bytes
    }

    func cborUnsigned(_ context: String) throws -> UInt64 {
        guard case .unsigned(let value) = self else {
            throw OwnerApprovalV2DTOError.malformedCBOR("\(context): expected unsigned integer")
        }
        return value
    }

    func cborArray(_ context: String) throws -> [HouseholdCBORValue] {
        guard case .array(let items) = self else {
            throw OwnerApprovalV2DTOError.malformedCBOR("\(context): expected array")
        }
        return items
    }
}

private func cborRequire(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> HouseholdCBORValue {
    guard let value = map[key] else {
        throw OwnerApprovalV2DTOError.malformedCBOR("\(context): missing key '\(key)'")
    }
    return value
}

private func cborUInt8(_ value: HouseholdCBORValue, _ context: String) throws -> UInt8 {
    let raw = try value.cborUnsigned(context)
    guard let narrowed = UInt8(exactly: raw) else {
        throw OwnerApprovalV2DTOError.malformedCBOR("\(context): \(raw) out of UInt8 range")
    }
    return narrowed
}

/// Optional text field: `nil` when the key is absent, throws when present but
/// not a text string.
private func cborOptionalText(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> String? {
    guard let value = map[key] else { return nil }
    return try value.cborText("\(context).\(key)")
}

/// Optional unsigned field: `nil` when absent, throws when present but not unsigned.
private func cborOptionalUnsigned(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> UInt64? {
    guard let value = map[key] else { return nil }
    return try value.cborUnsigned("\(context).\(key)")
}

/// Optional byte-string field: `nil` when absent, throws when present but not bytes.
private func cborOptionalBytes(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> Data? {
    guard let value = map[key] else { return nil }
    return try value.cborBytes("\(context).\(key)")
}

// MARK: - OwnerApprovalContextV2 decoder

public extension OwnerApprovalContextV2 {
    /// Decode a canonical-CBOR context (the form the server emits inside the
    /// approval-v2 envelope and start response). Fail-closed on a missing/typed
    /// field or an unknown operation. The byte-string fields (`nonce`,
    /// `join_request_hash`, `replay_nonce`) decode as raw `Data`.
    init(cbor: HouseholdCBORValue) throws {
        let map = try cbor.cborMap("context")
        let opText = try cborRequire(map, "op", "context").cborText("context.op")
        guard let op = OwnerApprovalOperation(rawValue: opText) else {
            throw OwnerApprovalV2DTOError.malformedCBOR("context.op: unknown operation '\(opText)'")
        }
        let capabilityValues = try cborRequire(map, "capabilities", "context").cborArray("context.capabilities")
        let capabilities = try capabilityValues.map { try $0.cborText("context.capabilities[]") }

        self.init(
            version: try cborUInt8(cborRequire(map, "v", "context"), "context.v"),
            purpose: try cborRequire(map, "purpose", "context").cborText("context.purpose"),
            op: op,
            householdID: try cborRequire(map, "hh_id", "context").cborText("context.hh_id"),
            ownerPersonID: try cborRequire(map, "owner_p_id", "context").cborText("context.owner_p_id"),
            cursor: try cborOptionalUnsigned(map, "cursor", "context"),
            machineID: try cborOptionalText(map, "m_id", "context"),
            addr: try cborOptionalText(map, "addr", "context"),
            transport: try cborOptionalText(map, "transport", "context"),
            ttlUnix: try cborOptionalUnsigned(map, "ttl_unix", "context"),
            nonce: try cborOptionalBytes(map, "nonce", "context"),
            joinRequestHash: try cborOptionalBytes(map, "join_request_hash", "context"),
            newCredentialBindingHash: try cborOptionalBytes(map, "new_credential_binding_hash", "context"),
            authorityHeadSequence: try cborOptionalUnsigned(map, "authority_head_sequence", "context"),
            authorityHeadHash: try cborOptionalBytes(map, "authority_head_hash", "context"),
            preActiveCredentialCount: try cborOptionalUnsigned(map, "pre_active_credential_count", "context"),
            capabilities: capabilities,
            issuedAt: try cborRequire(map, "issued_at", "context").cborUnsigned("context.issued_at"),
            expiresAt: try cborRequire(map, "expires_at", "context").cborUnsigned("context.expires_at"),
            replayNonce: try cborRequire(map, "replay_nonce", "context").cborBytes("context.replay_nonce")
        )
    }
}

// MARK: - OwnerApprovalV2 (signed approval envelope)

/// An owner's approval-v2 assertion over a privileged operation: the canonical
/// `context` plus the raw WebAuthn assertion the platform authenticator produced.
///
/// Wire note (the OPPOSITE of the WebAuthn registration DTOs): the assertion
/// fields here are CBOR **byte-strings** (`serde_bytes`/`ByteBuf` on the Rust
/// side), NOT base64url text. `user_handle` is OMITTED when absent, never null.
public struct OwnerApprovalV2: Sendable, Equatable {
    public static let currentVersion: UInt8 = 2

    public var version: UInt8
    public var context: OwnerApprovalContextV2
    public var credentialID: Data
    public var authenticatorData: Data
    public var clientDataJSON: Data
    public var signature: Data
    public var userHandle: Data?

    public init(
        version: UInt8 = OwnerApprovalV2.currentVersion,
        context: OwnerApprovalContextV2,
        credentialID: Data,
        authenticatorData: Data,
        clientDataJSON: Data,
        signature: Data,
        userHandle: Data? = nil
    ) {
        self.version = version
        self.context = context
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
        self.userHandle = userHandle
    }

    public func cborValue() -> HouseholdCBORValue {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(UInt64(version)),
            "context": context.cborValue(),
            "credential_id": .bytes(credentialID),
            "authenticator_data": .bytes(authenticatorData),
            "client_data_json": .bytes(clientDataJSON),
            "signature": .bytes(signature),
        ]
        if let userHandle {
            map["user_handle"] = .bytes(userHandle)
        }
        return .map(map)
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue())
    }
}

// MARK: - OwnerApprovalV2Finish (the /approve envelope body)

/// The canonical-CBOR body posted to `/owner-events/{cursor}/approve` to finish
/// an approval-v2 ceremony: the challenge id plus the signed approval.
public struct OwnerApprovalV2Finish: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public var version: UInt8
    public var challengeID: String
    public var approval: OwnerApprovalV2

    public init(
        version: UInt8 = OwnerApprovalV2Finish.currentVersion,
        challengeID: String,
        approval: OwnerApprovalV2
    ) {
        self.version = version
        self.challengeID = challengeID
        self.approval = approval
    }

    public func cborValue() -> HouseholdCBORValue {
        .map([
            "v": .unsigned(UInt64(version)),
            "challenge_id": .text(challengeID),
            "approval": approval.cborValue(),
        ])
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue())
    }
}

// MARK: - OwnerApprovalV2StartResponse (decoded start response)

/// The decoded `approval-v2/start` response. Surfaces only what the assertion
/// ceremony consumes (lean): the challenge id to echo on finish, the bound
/// `context`, and the platform-assertion options (rpId / challenge /
/// allow-credentials / user-verification). `challenge` and the allow-credential
/// ids are base64url **text** on the wire (webauthn `Base64UrlSafeData`) and are
/// decoded to raw `Data` here, at the edge.
public struct OwnerApprovalV2StartResponse: Sendable, Equatable {
    public let version: UInt8
    public let challengeID: String
    public let context: OwnerApprovalContextV2
    /// `options.publicKey.rpId`.
    public let relyingPartyIdentifier: String
    /// `options.publicKey.challenge`, base64url-decoded.
    public let challenge: Data
    /// `options.publicKey.allowCredentials[].id`, base64url-decoded. Empty when
    /// the server sends no restriction (key absent, `null`, or an empty array).
    public let allowedCredentialIDs: [Data]
    /// `options.publicKey.userVerification`, if present.
    public let userVerification: String?

    public init(cbor: HouseholdCBORValue) throws {
        let map = try cbor.cborMap("startResponse")
        version = try cborUInt8(cborRequire(map, "v", "startResponse"), "startResponse.v")
        challengeID = try cborRequire(map, "challenge_id", "startResponse")
            .cborText("startResponse.challenge_id")
        context = try OwnerApprovalContextV2(cbor: cborRequire(map, "context", "startResponse"))

        let options = try cborRequire(map, "options", "startResponse").cborMap("startResponse.options")
        let publicKey = try cborRequire(options, "publicKey", "options").cborMap("options.publicKey")

        relyingPartyIdentifier = try cborRequire(publicKey, "rpId", "publicKey")
            .cborText("publicKey.rpId")
        let challengeText = try cborRequire(publicKey, "challenge", "publicKey")
            .cborText("publicKey.challenge")
        guard let challengeData = PairingCrypto.base64URLDecode(challengeText) else {
            throw OwnerApprovalV2DTOError.malformedCBOR("publicKey.challenge: invalid base64url")
        }
        challenge = challengeData
        userVerification = try cborOptionalText(publicKey, "userVerification", "publicKey")
        allowedCredentialIDs = try Self.decodeAllowCredentialIDs(publicKey)
    }

    /// Collapse the three "no restriction" representations to `[]`: an absent
    /// key, an explicit `null`, or an empty array. Otherwise base64url-decode
    /// each `allowCredentials[].id`.
    private static func decodeAllowCredentialIDs(
        _ publicKey: [String: HouseholdCBORValue]
    ) throws -> [Data] {
        guard let value = publicKey["allowCredentials"] else { return [] }
        if case .null = value { return [] }
        let entries = try value.cborArray("publicKey.allowCredentials")
        return try entries.map { entry in
            let entryMap = try entry.cborMap("publicKey.allowCredentials[]")
            let idText = try cborRequire(entryMap, "id", "publicKey.allowCredentials[]")
                .cborText("publicKey.allowCredentials[].id")
            guard let id = PairingCrypto.base64URLDecode(idText) else {
                throw OwnerApprovalV2DTOError.malformedCBOR(
                    "publicKey.allowCredentials[].id: invalid base64url"
                )
            }
            return id
        }
    }
}
