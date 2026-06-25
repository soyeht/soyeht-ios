import CryptoKit
import Foundation
import Security

public enum ClawShareMemberIdentityError: Error, Equatable, Sendable {
    case secureEnclaveUnavailable
    case keyCreationFailed(OSStatus)
    case keyNotFound
    case publicKeyExtractFailed
    case signingFailed(OSStatus)
    case malformed
    case unsupportedVersion(UInt8)
    case kindMismatch(String)
    case memberIdMismatch
    case signatureRejected
}

public protocol ClawShareMemberIdentity: Sendable {
    var memberPublicKeyData: Data { get }
    var memberId: String { get }
    var keyReference: String? { get }
    func signMemberBytes(_ bytes: Data) throws -> Data
}

public protocol ClawShareMemberIdentityProviding: Sendable {
    func loadOrCreate() throws -> any ClawShareMemberIdentity
}

public struct EphemeralClawShareMemberIdentity: ClawShareMemberIdentity {
    private let privateKey: P256.Signing.PrivateKey
    public let memberPublicKeyData: Data
    public let memberId: String
    public let keyReference: String?

    public init() throws {
        try self.init(privateKey: P256.Signing.PrivateKey(), keyReference: nil)
    }

    init(rawRepresentation: Data, keyReference: String? = nil) throws {
        try self.init(
            privateKey: P256.Signing.PrivateKey(rawRepresentation: rawRepresentation),
            keyReference: keyReference
        )
    }

    private init(privateKey: P256.Signing.PrivateKey, keyReference: String?) throws {
        self.privateKey = privateKey
        self.memberPublicKeyData = privateKey.publicKey.compressedRepresentation
        self.memberId = try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberPublicKeyData)
        self.keyReference = keyReference
    }

    public func signMemberBytes(_ bytes: Data) throws -> Data {
        try privateKey.signature(for: bytes).rawRepresentation
    }
}

public struct EphemeralClawShareMemberIdentityProvider: ClawShareMemberIdentityProviding {
    public init() {}

    public func loadOrCreate() throws -> any ClawShareMemberIdentity {
        try EphemeralClawShareMemberIdentity()
    }
}

public struct SecureEnclaveClawShareMemberIdentity: ClawShareMemberIdentity, @unchecked Sendable {
    private let secKey: SecKey
    public let memberPublicKeyData: Data
    public let memberId: String
    public let keyReference: String?

    fileprivate init(secKey: SecKey, memberPublicKeyData: Data, keyReference: String) throws {
        self.secKey = secKey
        self.memberPublicKeyData = memberPublicKeyData
        self.memberId = try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberPublicKeyData)
        self.keyReference = keyReference
    }

    public func signMemberBytes(_ bytes: Data) throws -> Data {
        var unmanagedError: Unmanaged<CFError>?
        let derSignature = SecKeyCreateSignature(
            secKey,
            .ecdsaSignatureMessageX962SHA256,
            bytes as CFData,
            &unmanagedError
        )
        if let cfError = unmanagedError?.takeRetainedValue() {
            let nsError = cfError as Error as NSError
            throw ClawShareMemberIdentityError.signingFailed(OSStatus(nsError.code))
        }
        guard let derData = derSignature as Data? else {
            throw ClawShareMemberIdentityError.signingFailed(errSecParam)
        }
        return try P256.Signing.ECDSASignature(derRepresentation: derData).rawRepresentation
    }
}

public struct SecureEnclaveClawShareMemberIdentityProvider: ClawShareMemberIdentityProviding {
    public let keyReference: String
    public let allowSoftwareKeychainFallback: Bool

    public init(
        keyReference: String = Self.defaultKeyReference(),
        allowSoftwareKeychainFallback: Bool = Self.defaultAllowsSoftwareKeychainFallback()
    ) {
        self.keyReference = keyReference
        self.allowSoftwareKeychainFallback = allowSoftwareKeychainFallback
    }

    public static func defaultKeyReference(
        for profile: SoyehtInstallProfile = .current
    ) -> String {
        "\(profile.mobileKeychainService).claw-share.member"
    }

    public static func defaultAllowsSoftwareKeychainFallback() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public func loadOrCreate() throws -> any ClawShareMemberIdentity {
        if let loaded = try loadExistingKey() {
            return loaded
        }
        return try createKey()
    }

    private func loadExistingKey() throws -> SecureEnclaveClawShareMemberIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyReference.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let key = result, CFGetTypeID(key) == SecKeyGetTypeID() else {
            throw ClawShareMemberIdentityError.keyNotFound
        }
        return try identity(from: key as! SecKey)
    }

    private func createKey() throws -> SecureEnclaveClawShareMemberIdentity {
        let attributes: [String: Any]
        if SecureEnclave.isAvailable {
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                nil
            ) else {
                throw ClawShareMemberIdentityError.keyCreationFailed(errSecParam)
            }
            attributes = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: Data(keyReference.utf8),
                    kSecAttrAccessControl as String: accessControl,
                ],
            ]
        } else if allowSoftwareKeychainFallback {
            attributes = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: Data(keyReference.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ],
            ]
        } else {
            throw ClawShareMemberIdentityError.secureEnclaveUnavailable
        }

        var unmanagedError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &unmanagedError) else {
            let nsError = (unmanagedError?.takeRetainedValue() as Error?) as NSError?
            throw ClawShareMemberIdentityError.keyCreationFailed(
                OSStatus(nsError?.code ?? Int(errSecParam))
            )
        }
        return try identity(from: secKey)
    }

    private func identity(from secKey: SecKey) throws -> SecureEnclaveClawShareMemberIdentity {
        guard
            let publicSecKey = SecKeyCopyPublicKey(secKey),
            let publicKeyData = try Self.compressedPublicKey(from: publicSecKey)
        else {
            throw ClawShareMemberIdentityError.publicKeyExtractFailed
        }
        return try SecureEnclaveClawShareMemberIdentity(
            secKey: secKey,
            memberPublicKeyData: publicKeyData,
            keyReference: keyReference
        )
    }

    private static func compressedPublicKey(from key: SecKey) throws -> Data? {
        var unmanagedError: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &unmanagedError) as Data? else {
            _ = unmanagedError?.takeRetainedValue()
            throw ClawShareMemberIdentityError.publicKeyExtractFailed
        }
        if external.count == HouseholdIdentifiers.compressedP256PublicKeyLength {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(external)
            return external
        }
        guard external.count == 65, external.first == 0x04 else {
            return nil
        }
        let x = external[1..<33]
        let y = external[33..<65]
        let prefix: UInt8 = (y.last ?? 0).isMultiple(of: 2) ? 0x02 : 0x03
        let compressed = Data([prefix]) + x
        try HouseholdIdentifiers.validateCompressedP256PublicKey(compressed)
        return compressed
    }
}

public enum ClawShareMemberIdentifiers {
    public static let memberIdPrefix = "g_"
    public static let memberIdLength = memberIdPrefix.count + HouseholdIdentifiers.base32EncodedBLAKE3DigestLength

    public static func memberId(memberPublicKey: Data) throws -> String {
        try HouseholdIdentifiers.validateCompressedP256PublicKey(memberPublicKey)
        let digest = HouseholdHash.blake3(memberPublicKey)
        return "\(memberIdPrefix)\(HouseholdIdentifiers.base32LowerNoPadding(digest))"
    }
}

public struct MemberDeviceBinding: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind = "claw-share/member-device/v1"

    public let v: UInt8
    public let kind: String
    public let memberId: String
    public let memberPublicKey: Data
    public let devicePublicKey: Data
    public let participantNpub: String
    public let issuedAt: UInt64
    public let memberSignature: Data

    public init(
        v: UInt8 = MemberDeviceBinding.currentVersion,
        kind: String = MemberDeviceBinding.kind,
        memberId: String,
        memberPublicKey: Data,
        devicePublicKey: Data,
        participantNpub: String,
        issuedAt: UInt64,
        memberSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.memberId = memberId
        self.memberPublicKey = memberPublicKey
        self.devicePublicKey = devicePublicKey
        self.participantNpub = participantNpub
        self.issuedAt = issuedAt
        self.memberSignature = memberSignature
    }

    public static func sign(
        memberIdentity: any ClawShareMemberIdentity,
        devicePublicKey: Data,
        participantNpub: String,
        issuedAt: UInt64
    ) throws -> MemberDeviceBinding {
        try HouseholdIdentifiers.validateCompressedP256PublicKey(devicePublicKey)
        let unsigned = unsignedCBORValue(
            v: currentVersion,
            kind: kind,
            memberId: memberIdentity.memberId,
            memberPublicKey: memberIdentity.memberPublicKeyData,
            devicePublicKey: devicePublicKey,
            participantNpub: participantNpub,
            issuedAt: issuedAt
        )
        let signature = try memberIdentity.signMemberBytes(HouseholdCBOR.encode(unsigned))
        return MemberDeviceBinding(
            memberId: memberIdentity.memberId,
            memberPublicKey: memberIdentity.memberPublicKeyData,
            devicePublicKey: devicePublicKey,
            participantNpub: participantNpub,
            issuedAt: issuedAt,
            memberSignature: signature
        )
    }

    public func verify() throws {
        guard v == Self.currentVersion else {
            throw ClawShareMemberIdentityError.unsupportedVersion(v)
        }
        guard kind == Self.kind else {
            throw ClawShareMemberIdentityError.kindMismatch(kind)
        }
        try HouseholdIdentifiers.validateCompressedP256PublicKey(memberPublicKey)
        try HouseholdIdentifiers.validateCompressedP256PublicKey(devicePublicKey)
        guard memberId == (try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberPublicKey)) else {
            throw ClawShareMemberIdentityError.memberIdMismatch
        }
        guard memberSignature.count == 64 else {
            throw ClawShareMemberIdentityError.malformed
        }
        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(compressedRepresentation: memberPublicKey)
            signature = try P256.Signing.ECDSASignature(rawRepresentation: memberSignature)
        } catch {
            throw ClawShareMemberIdentityError.malformed
        }
        guard publicKey.isValidSignature(signature, for: unsignedSigningBytes()) else {
            throw ClawShareMemberIdentityError.signatureRejected
        }
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue)
    }

    public func unsignedSigningBytes() -> Data {
        HouseholdCBOR.encode(unsignedCborValue)
    }

    public static func fromCanonicalBytes(_ bytes: Data) throws -> MemberDeviceBinding {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw ClawShareMemberIdentityError.malformed
        }
        let map = try expectMap(value)
        guard Set(map.keys) == [
            "device_pub",
            "issued_at",
            "kind",
            "member_id",
            "member_pub",
            "member_signature",
            "participant_npub",
            "v",
        ] else {
            throw ClawShareMemberIdentityError.malformed
        }
        return MemberDeviceBinding(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            memberId: try expectText(map["member_id"]),
            memberPublicKey: try expectBytes(map["member_pub"]),
            devicePublicKey: try expectBytes(map["device_pub"]),
            participantNpub: try expectText(map["participant_npub"]),
            issuedAt: try expectUInt64(map["issued_at"]),
            memberSignature: try expectBytes(map["member_signature"])
        )
    }

    var cborValue: HouseholdCBORValue {
        var fields = unsignedMap
        fields["member_signature"] = .bytes(memberSignature)
        return .map(fields)
    }

    private var unsignedCborValue: HouseholdCBORValue {
        .map(unsignedMap)
    }

    private var unsignedMap: [String: HouseholdCBORValue] {
        Self.unsignedMap(
            v: v,
            kind: kind,
            memberId: memberId,
            memberPublicKey: memberPublicKey,
            devicePublicKey: devicePublicKey,
            participantNpub: participantNpub,
            issuedAt: issuedAt
        )
    }

    private static func unsignedCBORValue(
        v: UInt8,
        kind: String,
        memberId: String,
        memberPublicKey: Data,
        devicePublicKey: Data,
        participantNpub: String,
        issuedAt: UInt64
    ) -> HouseholdCBORValue {
        .map(unsignedMap(
            v: v,
            kind: kind,
            memberId: memberId,
            memberPublicKey: memberPublicKey,
            devicePublicKey: devicePublicKey,
            participantNpub: participantNpub,
            issuedAt: issuedAt
        ))
    }

    private static func unsignedMap(
        v: UInt8,
        kind: String,
        memberId: String,
        memberPublicKey: Data,
        devicePublicKey: Data,
        participantNpub: String,
        issuedAt: UInt64
    ) -> [String: HouseholdCBORValue] {
        [
            "device_pub": .bytes(devicePublicKey),
            "issued_at": .unsigned(issuedAt),
            "kind": .text(kind),
            "member_id": .text(memberId),
            "member_pub": .bytes(memberPublicKey),
            "participant_npub": .text(participantNpub),
            "v": .unsigned(UInt64(v)),
        ]
    }

    private static func expectMap(_ value: HouseholdCBORValue) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else { throw ClawShareMemberIdentityError.malformed }
        return map
    }

    private static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let text)) = value else { throw ClawShareMemberIdentityError.malformed }
        return text
    }

    private static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let bytes)) = value else { throw ClawShareMemberIdentityError.malformed }
        return bytes
    }

    private static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let number)) = value, number <= UInt64(UInt8.max) else {
            throw ClawShareMemberIdentityError.malformed
        }
        return UInt8(number)
    }

    private static func expectUInt64(_ value: HouseholdCBORValue?) throws -> UInt64 {
        guard case .some(.unsigned(let number)) = value else {
            throw ClawShareMemberIdentityError.malformed
        }
        return number
    }
}
