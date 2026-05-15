import Foundation
import LocalAuthentication
import Security

public enum OwnerIdentityKeyError: Error, Equatable, Sendable {
    case secureEnclaveUnavailable
    case accessControlUnavailable
    case keyCreationFailed(String)
    case publicKeyUnavailable
    case biometryCanceled
    case biometryLockout
    case signingFailed(String)
    case invalidSignatureEncoding
}

public protocol OwnerIdentitySigning: Sendable {
    var personId: String { get }
    var publicKey: Data { get }
    var keyReference: String { get }
    func sign(_ payload: Data) throws -> Data
}

public protocol OwnerIdentityKeyCreating: Sendable {
    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning
    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning
    func loadOwnerIdentity(
        keyReference: String,
        publicKey: Data,
        personId: String
    ) throws -> any OwnerIdentitySigning
}

public extension OwnerIdentityKeyCreating {
    func loadOwnerIdentity(
        keyReference: String,
        publicKey: Data,
        personId: String
    ) throws -> any OwnerIdentitySigning {
        try loadOwnerIdentity(keyReference: keyReference, publicKey: publicKey)
    }
}

public final class OwnerIdentityKey: OwnerIdentitySigning, @unchecked Sendable {
    public let personId: String
    public let publicKey: Data
    public let keyReference: String

    private let privateKey: SecKey

    public init(
        privateKey: SecKey,
        publicKey: Data,
        keyReference: String,
        personIdOverride: String? = nil
    ) throws {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.keyReference = keyReference
        if let personIdOverride {
            self.personId = personIdOverride
        } else {
            self.personId = try HouseholdIdentifiers.personIdentifier(for: publicKey)
        }
    }

    public func sign(_ payload: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &error
        ) as Data? else {
            if let cfError = error?.takeRetainedValue() {
                let nsError = cfError as Error as NSError
                if nsError.domain == NSOSStatusErrorDomain, nsError.code == Int(errSecUserCanceled) {
                    throw OwnerIdentityKeyError.biometryCanceled
                }
                if Self.isBiometryLockout(nsError) {
                    throw OwnerIdentityKeyError.biometryLockout
                }
                throw OwnerIdentityKeyError.signingFailed("security_signing_failed")
            }
            throw OwnerIdentityKeyError.signingFailed("security_signing_failed")
        }
        return try Self.rawP256Signature(fromDER: der)
    }

    /// SecKey wraps the underlying biometric failure as a CFError chain. When
    /// LocalAuthentication denies use because the biometric subsystem is
    /// locked (too many failed attempts), the LAError surfaces inside
    /// `NSUnderlyingErrorKey`. We surface it distinctly so the UI can prompt
    /// the operator to unlock the device, which is a different remediation
    /// from `.biometryCanceled` (operator hit Cancel).
    static func isBiometryLockout(_ nsError: NSError) -> Bool {
        var current: NSError? = nsError
        while let error = current {
            if error.domain == LAError.errorDomain,
               error.code == LAError.Code.biometryLockout.rawValue {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func rawP256Signature(fromDER der: Data) throws -> Data {
        var bytes = Array(der)
        guard bytes.count >= 8, bytes.removeFirst() == 0x30 else {
            throw OwnerIdentityKeyError.invalidSignatureEncoding
        }
        _ = try readLength(&bytes)
        guard bytes.removeFirst() == 0x02 else { throw OwnerIdentityKeyError.invalidSignatureEncoding }
        let r = try readInteger(&bytes)
        guard bytes.removeFirst() == 0x02 else { throw OwnerIdentityKeyError.invalidSignatureEncoding }
        let s = try readInteger(&bytes)
        return r + s
    }

    private static func readLength(_ bytes: inout [UInt8]) throws -> Int {
        guard !bytes.isEmpty else { throw OwnerIdentityKeyError.invalidSignatureEncoding }
        let first = bytes.removeFirst()
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 2, bytes.count >= count else {
            throw OwnerIdentityKeyError.invalidSignatureEncoding
        }
        var value = 0
        for _ in 0..<count {
            value = (value << 8) | Int(bytes.removeFirst())
        }
        return value
    }

    private static func readInteger(_ bytes: inout [UInt8]) throws -> Data {
        let length = try readLength(&bytes)
        guard bytes.count >= length else { throw OwnerIdentityKeyError.invalidSignatureEncoding }
        var integer = Array(bytes.prefix(length))
        bytes.removeFirst(length)
        while integer.count > 32, integer.first == 0 {
            integer.removeFirst()
        }
        guard integer.count <= 32 else { throw OwnerIdentityKeyError.invalidSignatureEncoding }
        return Data(repeating: 0, count: 32 - integer.count) + Data(integer)
    }
}

public enum SecureEnclaveOwnerIdentityKeyProtection: Sendable {
    case biometryCurrentSet
    case deviceUnlocked
}

public struct SecureEnclaveOwnerIdentityKeyProvider: OwnerIdentityKeyCreating {
    private let servicePrefix: String
    private let protection: SecureEnclaveOwnerIdentityKeyProtection

    public init(
        servicePrefix: String = "com.soyeht.household.owner",
        protection: SecureEnclaveOwnerIdentityKeyProtection = .biometryCurrentSet
    ) {
        self.servicePrefix = servicePrefix
        self.protection = protection
    }

    public func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        #if targetEnvironment(simulator)
        throw OwnerIdentityKeyError.secureEnclaveUnavailable
        #else
        let accessControlFlags: SecAccessControlCreateFlags = switch protection {
        case .biometryCurrentSet:
            [.privateKeyUsage, .biometryCurrentSet]
        case .deviceUnlocked:
            [.privateKeyUsage]
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessControlFlags,
            nil
        ) else {
            throw OwnerIdentityKeyError.accessControlUnavailable
        }

        let tag = "\(servicePrefix).\(UUID().uuidString)"
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessControl as String: access,
            ],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw OwnerIdentityKeyError.keyCreationFailed("security_key_creation_failed")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = try Self.compressedPublicKey(from: publicKey) else {
            throw OwnerIdentityKeyError.publicKeyUnavailable
        }
        return try OwnerIdentityKey(privateKey: privateKey, publicKey: publicData, keyReference: tag)
        #endif
    }

    public func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try loadOwnerIdentity(
            keyReference: keyReference,
            publicKey: publicKey,
            personId: try HouseholdIdentifiers.personIdentifier(for: publicKey)
        )
    }

    public func loadOwnerIdentity(
        keyReference: String,
        publicKey: Data,
        personId: String
    ) throws -> any OwnerIdentitySigning {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyReference.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let key = result else {
            throw OwnerIdentityKeyError.keyCreationFailed("key reference not found")
        }
        guard CFGetTypeID(key) == SecKeyGetTypeID() else {
            throw OwnerIdentityKeyError.keyCreationFailed("key reference invalid")
        }
        let privateKey = key as! SecKey
        return try OwnerIdentityKey(
            privateKey: privateKey,
            publicKey: publicKey,
            keyReference: keyReference,
            personIdOverride: personId
        )
    }

    private static func compressedPublicKey(from key: SecKey) throws -> Data? {
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            _ = error?.takeRetainedValue()
            throw OwnerIdentityKeyError.keyCreationFailed("security_public_key_export_failed")
        }
        if external.count == 33 { return external }
        guard external.count == 65, external.first == 0x04 else { return nil }
        let x = external[1..<33]
        let y = external[33..<65]
        let prefix: UInt8 = (y.last ?? 0).isMultiple(of: 2) ? 0x02 : 0x03
        return Data([prefix]) + x
    }
}

public struct InMemoryOwnerIdentityKey: OwnerIdentitySigning {
    public let personId: String
    public let publicKey: Data
    public let keyReference: String
    public let signer: @Sendable (Data) throws -> Data

    public init(
        publicKey: Data,
        keyReference: String = "test-owner-key",
        signer: @escaping @Sendable (Data) throws -> Data
    ) throws {
        self.publicKey = publicKey
        self.keyReference = keyReference
        self.personId = try HouseholdIdentifiers.personIdentifier(for: publicKey)
        self.signer = signer
    }

    public func sign(_ payload: Data) throws -> Data {
        try signer(payload)
    }
}
