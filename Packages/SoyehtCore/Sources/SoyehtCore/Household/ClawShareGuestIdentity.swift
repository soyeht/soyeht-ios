import Foundation
import CryptoKit
import Security

/// Abstraction over the friend's per-share P-256 device key.
///
/// Two implementations live alongside each other so the same friend-side
/// claim flow can run with an in-process key (tests, harness, simulator)
/// OR a Secure Enclave-backed key (production on supported hardware) by
/// just swapping the provider.
///
/// Guest identity model:
/// - **Fresh per share.** A new key for every claw-share invite the
///   friend accepts. No long-lived linkage to Apple ID, email, phone.
/// - **No biometric prompt.** Unlike owner pair-device, the guest key
///   does not require biometry — adding it would push friction onto a
///   third party tapping a link they didn't initiate.
/// - **Resistant to key extraction.** The SE-backed impl keeps the
///   private scalar inside the Secure Enclave; a compromised app
///   cannot exfiltrate it.

// MARK: - Protocols

public protocol ClawShareGuestIdentity: Sendable {
    /// 33-byte SEC1-compressed P-256 public key — wire-equal to the
    /// host's `P256PublicKey`.
    var publicKeyData: Data { get }

    /// Produce a 64-byte raw `r || s` ECDSA P-256 signature over the
    /// provided message. Mirrors the host's `IdentityKey::sign`.
    func sign(_ data: Data) throws -> Data
}

public protocol ClawShareGuestIdentityProvider: Sendable {
    /// Create a fresh guest identity bound to this provider's backing
    /// (in-process vs. Secure Enclave).
    func create() throws -> any ClawShareGuestIdentity
}

// MARK: - Ephemeral (in-process) impl

/// In-process P256 keypair used by tests, the in-host friend harness,
/// and any flow that doesn't have SE access. The private scalar lives
/// in process memory for the lifetime of the value.
public struct EphemeralClawShareGuestIdentity: ClawShareGuestIdentity {
    fileprivate let privateKey: P256.Signing.PrivateKey
    public let publicKeyData: Data

    public init() {
        let key = P256.Signing.PrivateKey()
        self.privateKey = key
        self.publicKeyData = key.publicKey.compressedRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return signature.rawRepresentation
    }
}

public struct EphemeralClawShareGuestIdentityProvider: ClawShareGuestIdentityProvider {
    public init() {}

    public func create() throws -> any ClawShareGuestIdentity {
        EphemeralClawShareGuestIdentity()
    }
}

// MARK: - Secure Enclave impl (production)

public enum SecureEnclaveClawShareGuestIdentityError: Error, Sendable {
    case secureEnclaveUnavailable
    case keyCreationFailed(OSStatus)
    case publicKeyExtractFailed
    case signingFailed(OSStatus)
}

/// Secure Enclave-backed guest identity. The 32-byte private scalar
/// never leaves the SE. Signature operations route through `SecKeyCreateSignature`
/// with the `ecdsaSignatureMessageX962SHA256` algorithm; the resulting DER
/// signature is converted to 64-byte raw `r || s` before returning.
///
/// The key reference is NOT persisted — the friend's device generates a
/// fresh key per share, uses it for the claim, and discards it. If we
/// later need to re-attest the credential (e.g. WebSocket reconnect),
/// the in-memory `SecKey` reference must still be alive. Persistence
/// across app launches is a separate concern handled by callers (saving
/// `kSecAttrApplicationTag` and reloading via `SecItemCopyMatching`),
/// not by this minimal impl.
///
/// Tagged `@unchecked Sendable` because `SecKey` is reference-counted
/// CoreFoundation; we don't mutate after init.
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
        if let cfErr = unmanagedError?.takeRetainedValue() {
            let nsErr = cfErr as Error as NSError
            throw SecureEnclaveClawShareGuestIdentityError.signingFailed(OSStatus(nsErr.code))
        }
        guard let derData = derSignature as Data? else {
            throw SecureEnclaveClawShareGuestIdentityError.signingFailed(errSecParam)
        }
        // SE returns a DER-encoded ECDSA signature; CryptoKit can parse
        // it and re-emit raw `r || s`.
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: derData)
        return parsed.rawRepresentation
    }
}

public struct SecureEnclaveClawShareGuestIdentityProvider: ClawShareGuestIdentityProvider {
    /// When non-empty, the provider tries to load an existing SE key
    /// with this `kSecAttrApplicationTag` first. On miss, a new
    /// permanent key is created and stored under the same tag so
    /// subsequent shares from this device sign with the same `npub`.
    /// This is how the engine recognizes Alice's iPhone two months
    /// later (same `guest_device_pub`, same projected `foreign_contact`).
    ///
    /// Empty tag (`""`) preserves the original "fresh per share"
    /// behaviour — used by unit tests + ad-hoc flows that intentionally
    /// don't want continuity.
    private let persistentTag: String

    public init(persistentTag: String = "") {
        self.persistentTag = persistentTag
    }

    /// Default device-identity tag for the canonical "this iPhone"
    /// claw-share key. Production wires `SecureEnclaveClawShareGuestIdentityProvider(persistentTag: .deviceIdentity)`.
    public static let deviceIdentityTag = "com.soyeht.claw-share.device-identity.v1"

    /// Convenience: production-grade provider tied to the device.
    public static func deviceIdentity() -> SecureEnclaveClawShareGuestIdentityProvider {
        SecureEnclaveClawShareGuestIdentityProvider(persistentTag: deviceIdentityTag)
    }

    public func create() throws -> any ClawShareGuestIdentity {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveClawShareGuestIdentityError.secureEnclaveUnavailable
        }
        if !persistentTag.isEmpty, let existing = try Self.loadByTag(persistentTag) {
            return existing
        }
        return try Self.createKey(persistentTag: persistentTag)
    }

    /// Lookup an existing SE key by application tag. Returns nil when
    /// no key is stored under that tag yet.
    fileprivate static func loadByTag(_ tag: String) throws -> SecureEnclaveClawShareGuestIdentity? {
        let tagData = Data(tag.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: tagData,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw SecureEnclaveClawShareGuestIdentityError.keyCreationFailed(status)
        }
        // SecItemCopyMatching returns a SecKey when kSecReturnRef = true.
        // The cast is safe because we filtered by kSecClassKey + EC key
        // type; CoreFoundation reference counting is handled by ARC for
        // the bridged value.
        guard CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        let secKey = result as! SecKey
        guard
            let pubSecKey = SecKeyCopyPublicKey(secKey),
            let pubRepresentation = SecKeyCopyExternalRepresentation(pubSecKey, nil) as Data?
        else {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        let pubKey: P256.Signing.PublicKey
        do {
            pubKey = try P256.Signing.PublicKey(x963Representation: pubRepresentation)
        } catch {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        return SecureEnclaveClawShareGuestIdentity(
            secKey: secKey,
            publicKeyData: pubKey.compressedRepresentation
        )
    }

    fileprivate static func createKey(persistentTag: String) throws -> SecureEnclaveClawShareGuestIdentity {
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            nil
        )
        let isPermanent = !persistentTag.isEmpty
        var privAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: isPermanent,
        ]
        if isPermanent {
            privAttrs[kSecAttrApplicationTag as String] = Data(persistentTag.utf8)
        }
        if let accessControl {
            privAttrs[kSecAttrAccessControl as String] = accessControl
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privAttrs,
        ]
        var unmanagedError: Unmanaged<CFError>?
        guard
            let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &unmanagedError)
        else {
            let nsErr = (unmanagedError?.takeRetainedValue() as Error?) as NSError?
            throw SecureEnclaveClawShareGuestIdentityError.keyCreationFailed(
                OSStatus(nsErr?.code ?? Int(errSecParam))
            )
        }
        guard
            let pubSecKey = SecKeyCopyPublicKey(secKey),
            let pubRepresentation = SecKeyCopyExternalRepresentation(pubSecKey, nil) as Data?
        else {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        let pubKey: P256.Signing.PublicKey
        do {
            pubKey = try P256.Signing.PublicKey(x963Representation: pubRepresentation)
        } catch {
            throw SecureEnclaveClawShareGuestIdentityError.publicKeyExtractFailed
        }
        return SecureEnclaveClawShareGuestIdentity(
            secKey: secKey,
            publicKeyData: pubKey.compressedRepresentation
        )
    }
}
