import CryptoKit
import Foundation

public enum PersonCertError: Error, Equatable {
    case malformed
    case unsupportedVersion
    case wrongType
    case deviceCertNotAllowed
    case invalidPersonPublicKey
    case personIdMismatch
    case householdMismatch
    case ownerIdentityMismatch
    case invalidValidityWindow
    case invalidIssuer
    case invalidNonce
    case invalidCaveatShape
    case invalidDisplayName
    case missingOwnerCaveats
    case invalidSignature
}

public enum PersonCertCaveatScope: String, Codable, Equatable, Sendable {
    case none
    case all
    case other
}

public struct PersonCertCaveat: Codable, Equatable, Sendable {
    public let operation: String
    public let scopeDescription: String?
    public let scope: PersonCertCaveatScope
    public let hasConstraints: Bool

    public init(
        operation: String,
        scopeDescription: String? = nil,
        scope: PersonCertCaveatScope? = nil,
        hasConstraints: Bool = false
    ) {
        self.operation = operation
        self.scopeDescription = scopeDescription
        self.scope = scope ?? Self.defaultScope(for: operation)
        self.hasConstraints = hasConstraints
    }

    private static func defaultScope(for operation: String) -> PersonCertCaveatScope {
        if operation.hasPrefix("claws.") { return .all }
        if operation.hasPrefix("household.") { return .none }
        return .other
    }
}

public struct PersonCert: Codable, Equatable, Sendable {
    public static let requiredOwnerOperations: Set<String> = [
        "claws.list",
        "claws.create",
        "claws.delete",
        "claws.use",
        "claws.assign",
        "household.invite",
        "household.revoke",
        "household.add_machine",
    ]

    public let rawCBOR: Data
    public let version: Int
    public let type: String
    public let householdId: String
    public let personId: String
    public let personPublicKey: Data
    public let displayName: String
    public let caveats: [PersonCertCaveat]
    public let notBefore: Date
    public let notAfter: Date?
    public let issuedAt: Date?
    public let issuedBy: String
    public let nonce: Data
    public let signature: Data

    private enum CodingKeys: String, CodingKey {
        case rawCBOR
    }

    public init(cbor: Data) throws {
        guard case .map(let map) = try HouseholdCBOR.decode(cbor) else {
            throw PersonCertError.malformed
        }
        if Self.containsProhibitedDeviceCertKey(map) {
            throw PersonCertError.deviceCertNotAllowed
        }
        self.rawCBOR = cbor
        self.version = try map.requiredUInt("v")
        self.type = try map.requiredText("type")
        self.householdId = try map.requiredText("hh_id")
        self.personId = try map.requiredText("p_id")
        self.personPublicKey = try map.requiredBytes("p_pub")
        self.displayName = try map.optionalText("display_name") ?? "Owner"
        self.caveats = try map.requiredArray("caveats").map(Self.decodeCaveat)
        self.notBefore = Date(timeIntervalSince1970: TimeInterval(try map.requiredUInt("not_before")))
        if let notAfter = try map.optionalUIntOrNull("not_after") {
            self.notAfter = Date(timeIntervalSince1970: TimeInterval(notAfter))
        } else {
            self.notAfter = nil
        }
        if let issuedAt = try map.optionalUIntOrNull("issued_at") {
            self.issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedAt))
        } else {
            self.issuedAt = nil
        }
        self.issuedBy = try map.requiredText("issued_by")
        self.nonce = try map.requiredBytes("nonce")
        self.signature = try map.requiredBytes("signature")

        guard version == 1 else { throw PersonCertError.unsupportedVersion }
        guard type == "person" else { throw PersonCertError.wrongType }
        guard signature.count == 64 else { throw PersonCertError.invalidSignature }
        guard nonce.count == 16 else { throw PersonCertError.invalidNonce }
        guard Self.isValidDisplayName(displayName) else { throw PersonCertError.invalidDisplayName }
        if let issuedAt, notBefore > issuedAt {
            throw PersonCertError.invalidValidityWindow
        }
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(personPublicKey)
        } catch {
            throw PersonCertError.invalidPersonPublicKey
        }
        guard try HouseholdIdentifiers.personIdentifier(for: personPublicKey) == personId else {
            throw PersonCertError.personIdMismatch
        }
    }

    public init(
        rawCBOR: Data,
        version: Int,
        type: String,
        householdId: String,
        personId: String,
        personPublicKey: Data,
        displayName: String,
        caveats: [PersonCertCaveat],
        notBefore: Date,
        notAfter: Date?,
        issuedAt: Date?,
        issuedBy: String,
        nonce: Data = Data(repeating: 0, count: 16),
        signature: Data
    ) {
        self.rawCBOR = rawCBOR
        self.version = version
        self.type = type
        self.householdId = householdId
        self.personId = personId
        self.personPublicKey = personPublicKey
        self.displayName = displayName
        self.caveats = caveats
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.issuedAt = issuedAt
        self.issuedBy = issuedBy
        self.nonce = nonce
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCBOR = try container.decode(Data.self, forKey: .rawCBOR)
        self = try Self(cbor: rawCBOR)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawCBOR, forKey: .rawCBOR)
    }

    public func validate(
        householdId expectedHouseholdId: String,
        householdPublicKey: Data,
        ownerPersonId: String,
        ownerPersonPublicKey: Data,
        now: Date = Date()
    ) throws {
        guard householdId == expectedHouseholdId else { throw PersonCertError.householdMismatch }
        guard personId == ownerPersonId, personPublicKey == ownerPersonPublicKey else {
            throw PersonCertError.ownerIdentityMismatch
        }
        guard notBefore <= now, notAfter.map({ now < $0 }) ?? true else {
            throw PersonCertError.invalidValidityWindow
        }
        guard issuedBy == expectedHouseholdId || issuedBy == "hh:\(expectedHouseholdId)" else {
            throw PersonCertError.invalidIssuer
        }
        guard nonce.count == 16 else { throw PersonCertError.invalidNonce }
        guard hasOwnerCapabilities else { throw PersonCertError.missingOwnerCaveats }
        try verifySignature(householdPublicKey: householdPublicKey)
    }

    public var hasOwnerCapabilities: Bool {
        Self.requiredOwnerOperations.allSatisfy { allows($0) }
    }

    public func allows(_ operation: String) -> Bool {
        caveats.contains { caveat in
            guard caveat.operation == operation, !caveat.hasConstraints else { return false }
            if operation.hasPrefix("claws.") {
                return caveat.scope == .all
            }
            if operation.hasPrefix("household.") {
                return caveat.scope == .none
            }
            return false
        }
    }

    private func verifySignature(householdPublicKey: Data) throws {
        let signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(rawCBOR, removing: "signature")
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(signature, for: signingBytes) else {
                throw PersonCertError.invalidSignature
            }
        } catch let error as PersonCertError {
            throw error
        } catch {
            throw PersonCertError.invalidSignature
        }
    }

    private static func decodeCaveat(_ value: HouseholdCBORValue) throws -> PersonCertCaveat {
        guard case .map(let map) = value else { throw PersonCertError.malformed }
        let operation = try map.requiredText("op")
        let scopeValue = map["scope"] ?? .null
        let constraintsValue = map["constraints"] ?? .null
        return PersonCertCaveat(
            operation: operation,
            scopeDescription: Self.scopeDescription(from: scopeValue),
            scope: try Self.decodeScope(scopeValue),
            hasConstraints: !Self.isNull(constraintsValue)
        )
    }

    private static func decodeScope(_ value: HouseholdCBORValue) throws -> PersonCertCaveatScope {
        switch value {
        case .null:
            return .none
        case .map(let map):
            if map.count == 1, case .bool(true) = map["all"] {
                return .all
            }
            return .other
        default:
            return .other
        }
    }

    private static func scopeDescription(from value: HouseholdCBORValue) -> String? {
        if case .text(let text) = value { return text }
        return nil
    }

    private static func isNull(_ value: HouseholdCBORValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func containsProhibitedDeviceCertKey(_ map: [String: HouseholdCBORValue]) -> Bool {
        map.keys.contains { key in
            let canonical = key
                .replacingOccurrences(of: "-", with: "_")
                .lowercased()
            return canonical == "device_cert" || canonical == "devicecert"
        }
    }

    private static func isValidDisplayName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func requiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw PersonCertError.malformed }
        return value
    }

    func optionalText(_ key: String) throws -> String? {
        guard let value = self[key] else { return nil }
        guard case .text(let text) = value else { throw PersonCertError.malformed }
        return text
    }

    func requiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else { throw PersonCertError.malformed }
        return value
    }

    func requiredUInt(_ key: String) throws -> Int {
        guard case .unsigned(let value) = self[key] else { throw PersonCertError.malformed }
        return Int(value)
    }

    func optionalUIntOrNull(_ key: String) throws -> Int? {
        guard let value = self[key] else { return nil }
        switch value {
        case .unsigned(let number): return Int(number)
        case .null: return nil
        default: throw PersonCertError.malformed
        }
    }

    func requiredArray(_ key: String) throws -> [HouseholdCBORValue] {
        guard case .array(let value) = self[key] else { throw PersonCertError.malformed }
        return value
    }
}
