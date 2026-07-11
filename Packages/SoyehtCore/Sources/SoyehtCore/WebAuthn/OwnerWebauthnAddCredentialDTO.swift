import Foundation

/// Typed DTOs for the owner WebAuthn AddCredential dual-ceremony wire.
///
/// The nested `registration` block reuses the owner WebAuthn registration DTOs,
/// where WebAuthn attestation fields are base64url CBOR text. The nested
/// `approval` block reuses approval-v2, where WebAuthn assertion fields are
/// CBOR byte strings. These wrapper DTOs pin only the composite envelope shape.
public enum OwnerWebauthnAddCredentialDTOError: Error, Equatable, Sendable {
    case malformedCBOR(String)
}

private extension HouseholdCBORValue {
    func addCredentialCBORMap(_ context: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = self else {
            throw OwnerWebauthnAddCredentialDTOError.malformedCBOR("\(context): expected map")
        }
        return map
    }

    func addCredentialCBORUnsigned(_ context: String) throws -> UInt64 {
        guard case .unsigned(let value) = self else {
            throw OwnerWebauthnAddCredentialDTOError.malformedCBOR("\(context): expected unsigned integer")
        }
        return value
    }

    func addCredentialCBORBytes(_ context: String) throws -> Data {
        guard case .bytes(let value) = self else {
            throw OwnerWebauthnAddCredentialDTOError.malformedCBOR("\(context): expected byte string")
        }
        return value
    }
}

private func addCredentialCBORRequire(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> HouseholdCBORValue {
    guard let value = map[key] else {
        throw OwnerWebauthnAddCredentialDTOError.malformedCBOR("\(context): missing key '\(key)'")
    }
    return value
}

private func addCredentialCBORUInt8(_ value: HouseholdCBORValue, _ context: String) throws -> UInt8 {
    let raw = try value.addCredentialCBORUnsigned(context)
    guard let narrowed = UInt8(exactly: raw) else {
        throw OwnerWebauthnAddCredentialDTOError.malformedCBOR("\(context): \(raw) out of UInt8 range")
    }
    return narrowed
}

/// `/owner-webauthn/add-credential/start` request body: canonical CBOR `{ v: 1 }`.
public struct OwnerWebauthnAddCredentialStartRequest: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8

    public init(version: UInt8 = Self.currentVersion) {
        self.version = version
    }

    public func cborValue() -> HouseholdCBORValue {
        .map(["v": .unsigned(UInt64(version))])
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue())
    }
}

/// `/owner-webauthn/add-credential/start` response wrapper. The top-level
/// `context` is authoritative; `approval.context` mirrors it for decoder reuse.
public struct OwnerWebauthnAddCredentialStartResponse: Equatable, Sendable {
    public let version: UInt8
    public let registration: OwnerWebauthnRegistrationStartResponse
    public let approval: OwnerApprovalV2StartResponse
    public let context: OwnerApprovalContextV2

    public init(cbor: HouseholdCBORValue) throws {
        let map = try cbor.addCredentialCBORMap("addCredentialStartResponse")
        version = try addCredentialCBORUInt8(
            addCredentialCBORRequire(map, "v", "addCredentialStartResponse"),
            "addCredentialStartResponse.v"
        )
        registration = try OwnerWebauthnRegistrationStartResponse(
            cbor: addCredentialCBORRequire(map, "registration", "addCredentialStartResponse")
        )
        approval = try OwnerApprovalV2StartResponse(
            cbor: addCredentialCBORRequire(map, "approval", "addCredentialStartResponse")
        )
        context = try OwnerApprovalContextV2(
            cbor: addCredentialCBORRequire(map, "context", "addCredentialStartResponse")
        )
        guard try approval.context.canonicalBytes() == context.canonicalBytes() else {
            throw OwnerWebauthnAddCredentialDTOError.malformedCBOR(
                "addCredentialStartResponse.approval.context: mirrored context does not match top-level context"
            )
        }
    }
}

/// `/owner-webauthn/add-credential/finish` request wrapper. The client echoes
/// the authoritative top-level `context` and sends the registration attestation
/// and approval assertion in their existing nested shapes.
public struct OwnerWebauthnAddCredentialFinishRequest: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let context: OwnerApprovalContextV2
    public let registration: OwnerWebauthnRegistrationFinishRequest
    public let approval: OwnerApprovalV2Finish

    public init(
        version: UInt8 = Self.currentVersion,
        context: OwnerApprovalContextV2,
        registration: OwnerWebauthnRegistrationFinishRequest,
        approval: OwnerApprovalV2Finish
    ) {
        self.version = version
        self.context = context
        self.registration = registration
        self.approval = approval
    }

    public func cborValue() throws -> HouseholdCBORValue {
        .map([
            "v": .unsigned(UInt64(version)),
            "context": try context.cborValue(),
            "registration": registration.cborValue(),
            "approval": try approval.cborValue(),
        ])
    }

    public func canonicalBytes() throws -> Data {
        HouseholdCBOR.encode(try cborValue())
    }
}

/// Result returned by the AddCredential finish endpoint after the WebAuthn Add
/// is appended and the active credential count advances by one.
public struct OwnerWebauthnAddCredentialResult: Equatable, Sendable {
    public let credentialID: Data
    public let activeCredentialCount: UInt64

    public init(credentialID: Data, activeCredentialCount: UInt64) {
        self.credentialID = credentialID
        self.activeCredentialCount = activeCredentialCount
    }
}

/// `/owner-webauthn/add-credential/finish` response body.
public struct OwnerWebauthnAddCredentialFinishResponse: Equatable, Sendable {
    public let version: UInt8
    public let credentialID: Data
    public let activeCredentialCount: UInt64

    public init(cbor: HouseholdCBORValue) throws {
        let map = try cbor.addCredentialCBORMap("addCredentialFinishResponse")
        version = try addCredentialCBORUInt8(
            addCredentialCBORRequire(map, "v", "addCredentialFinishResponse"),
            "addCredentialFinishResponse.v"
        )
        credentialID = try addCredentialCBORRequire(
            map,
            "credential_id",
            "addCredentialFinishResponse"
        ).addCredentialCBORBytes("addCredentialFinishResponse.credential_id")
        activeCredentialCount = try addCredentialCBORRequire(
            map,
            "active_credential_count",
            "addCredentialFinishResponse"
        ).addCredentialCBORUnsigned("addCredentialFinishResponse.active_credential_count")
    }
}
