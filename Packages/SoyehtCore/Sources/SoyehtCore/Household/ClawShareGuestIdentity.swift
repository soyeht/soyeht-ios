import CryptoKit
import Foundation
import Security

public protocol ClawShareGuestIdentity: Sendable {
    var publicKeyData: Data { get }
    func sign(_ data: Data) throws -> Data
}

public protocol ClawShareGuestIdentityProvider: Sendable {
    func create() throws -> any ClawShareGuestIdentity
}

public struct EphemeralClawShareGuestIdentity: ClawShareGuestIdentity {
    private let privateKey: P256.Signing.PrivateKey
    public let publicKeyData: Data

    public init() {
        let key = P256.Signing.PrivateKey()
        self.privateKey = key
        self.publicKeyData = key.publicKey.compressedRepresentation
    }

    init(rawRepresentation: Data) throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        self.privateKey = key
        self.publicKeyData = key.publicKey.compressedRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}

public struct EphemeralClawShareGuestIdentityProvider: ClawShareGuestIdentityProvider {
    public init() {}

    public func create() throws -> any ClawShareGuestIdentity {
        EphemeralClawShareGuestIdentity()
    }
}

public enum SecureEnclaveClawShareGuestIdentityError: Error, Sendable {
    case secureEnclaveUnavailable
    case keyCreationFailed(OSStatus)
    case publicKeyExtractFailed
    case signingFailed(OSStatus)
}

public struct SecureEnclaveClawShareGuestIdentity: ClawShareGuestIdentity, @unchecked Sendable {
    private let secKey: SecKey
    public let publicKeyData: Data

    fileprivate init(secKey: SecKey, publicKeyData: Data) {
        self.secKey = secKey
        self.publicKeyData = publicKeyData
    }

    public func sign(_ data: Data) throws -> Data {
        var unmanagedError: Unmanaged<CFError>?
        let derSignature = SecKeyCreateSignature(
            secKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &unmanagedError
        )
        if let cfError = unmanagedError?.takeRetainedValue() {
            let nsError = cfError as Error as NSError
            throw SecureEnclaveClawShareGuestIdentityError.signingFailed(OSStatus(nsError.code))
        }
        guard let derData = derSignature as Data? else {
            throw SecureEnclaveClawShareGuestIdentityError.signingFailed(errSecParam)
        }
        return try P256.Signing.ECDSASignature(derRepresentation: derData).rawRepresentation
    }
}

public struct SecureEnclaveClawShareGuestIdentityProvider: ClawShareGuestIdentityProvider {
    public init() {}

    public func create() throws -> any ClawShareGuestIdentity {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveClawShareGuestIdentityError.secureEnclaveUnavailable
        }
        return try Self.createKey()
    }

    private static func createKey() throws -> SecureEnclaveClawShareGuestIdentity {
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            nil
        )
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: false,
        ]
        if let accessControl {
            privateAttributes[kSecAttrAccessControl as String] = accessControl
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var unmanagedError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &unmanagedError) else {
            let nsError = (unmanagedError?.takeRetainedValue() as Error?) as NSError?
            throw SecureEnclaveClawShareGuestIdentityError.keyCreationFailed(
                OSStatus(nsError?.code ?? Int(errSecParam))
            )
        }
        return try identity(from: secKey)
    }

    private static func identity(from secKey: SecKey) throws -> SecureEnclaveClawShareGuestIdentity {
        guard
            let publicSecKey = SecKeyCopyPublicKey(secKey),
            let publicRepresentation = SecKeyCopyExternalRepresentation(publicSecKey, nil) as Data?
        else {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: publicRepresentation)
        } catch {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        return SecureEnclaveClawShareGuestIdentity(
            secKey: secKey,
            publicKeyData: publicKey.compressedRepresentation
        )
    }
}
