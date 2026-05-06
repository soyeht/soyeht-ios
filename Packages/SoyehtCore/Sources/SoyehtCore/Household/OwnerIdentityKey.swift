import Foundation
import Security

public enum OwnerIdentityKeyError: Error, Equatable {
    case secureEnclaveUnavailable
    case accessControlUnavailable
    case keyCreationFailed(String)
    case publicKeyUnavailable
    case biometryCanceled
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
}

public final class OwnerIdentityKey: OwnerIdentitySigning, @unchecked Sendable {
    public let personId: String
    public let publicKey: Data
    public let keyReference: String

    private let privateKey: SecKey

    public init(privateKey: SecKey, publicKey: Data, keyReference: String) throws {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.keyReference = keyReference
        self.personId = try HouseholdIdentifiers.personIdentifier(for: publicKey)
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
                throw OwnerIdentityKeyError.signingFailed(nsError.localizedDescription)
            }
            throw OwnerIdentityKeyError.signingFailed("unknown")
        }
        return try Self.rawP256Signature(fromDER: der)
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

public struct SecureEnclaveOwnerIdentityKeyProvider: OwnerIdentityKeyCreating {
    private let servicePrefix: String

    public init(servicePrefix: String = "com.soyeht.household.owner") {
        self.servicePrefix = servicePrefix
    }

    public func createOwnerIdentity(displayName: String = "Caio") throws -> any OwnerIdentitySigning {
        #if targetEnvironment(simulator)
        throw OwnerIdentityKeyError.secureEnclaveUnavailable
        #else
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
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
            throw OwnerIdentityKeyError.keyCreationFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = try Self.compressedPublicKey(from: publicKey) else {
            throw OwnerIdentityKeyError.publicKeyUnavailable
        }
        return try OwnerIdentityKey(privateKey: privateKey, publicKey: publicData, keyReference: tag)
        #endif
    }

    public func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
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
        return try OwnerIdentityKey(privateKey: key as! SecKey, publicKey: publicKey, keyReference: keyReference)
    }

    private static func compressedPublicKey(from key: SecKey) throws -> Data? {
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw OwnerIdentityKeyError.keyCreationFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
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
