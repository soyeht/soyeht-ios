import Foundation
import P256K
import Security

/// The resolved Keychain Access Group used only for the mesh identity.
///
/// The entitlement contains `$(AppIdentifierPrefix)`, which is expanded at
/// signing time. Code must therefore read the fully expanded value from the
/// target's Info.plist rather than pass a build-setting literal to Security.
/// This intentionally does not consult `SoyehtInstallProfile`: an app
/// extension bundle identifier has a different suffix shape from its host.
public struct MeshTunnelKeychainAccessGroup: Equatable, Sendable {
    public static let infoDictionaryKey = "MeshTunnelKeychainAccessGroup"

    public let value: String

    public init(resolvedValue: String) throws {
        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let meshSuffixes = [
            "com.soyeht.mobile.clawshare.mesh.dev",
            "com.soyeht.mobile.clawshare.mesh",
        ]
        guard !resolvedValue.isEmpty,
              !resolvedValue.contains("$("),
              !resolvedValue.unicodeScalars.contains(where: forbiddenCharacters.contains),
              let suffix = meshSuffixes.first(where: resolvedValue.hasSuffix)
        else {
            throw MeshTunnelIdentityNsecStoreError.invalidAccessGroup
        }
        let prefix = resolvedValue.dropLast(suffix.count)
        guard
              prefix.last == ".",
              !prefix.dropLast().isEmpty,
              prefix.dropLast().allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) })
        else {
            throw MeshTunnelIdentityNsecStoreError.invalidAccessGroup
        }
        self.value = resolvedValue
    }

    public static func resolve(from bundle: Bundle = .main) throws -> Self {
        guard let value = bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String else {
            throw MeshTunnelIdentityNsecStoreError.accessGroupUnavailable
        }
        return try Self(resolvedValue: value)
    }
}

/// Narrow Keychain storage for the secp256k1 mesh identity. It is deliberately
/// separate from `KeychainHelper`: every query explicitly selects the shared
/// group, there is no ungrouped fallback, and updates never delete first.
public struct MeshTunnelIdentityNsecStore: Sendable {
    public static let defaultService = "com.soyeht.mesh.identity.v1"
    public static let defaultAccount = "identity-nsec"

    private let accessGroup: MeshTunnelKeychainAccessGroup
    private let service: String
    private let account: String
    private let operations: any MeshTunnelKeychainOperating

    public init(
        accessGroup: MeshTunnelKeychainAccessGroup,
        service: String = MeshTunnelIdentityNsecStore.defaultService,
        account: String = MeshTunnelIdentityNsecStore.defaultAccount
    ) {
        self.init(
            accessGroup: accessGroup,
            service: service,
            account: account,
            operations: SystemMeshTunnelKeychainOperations()
        )
    }

    init(
        accessGroup: MeshTunnelKeychainAccessGroup,
        service: String,
        account: String,
        operations: any MeshTunnelKeychainOperating
    ) {
        self.accessGroup = accessGroup
        self.service = service
        self.account = account
        self.operations = operations
    }

    /// Returns the raw 32-byte secp256k1 scalar. Callers must keep it in memory
    /// only long enough to render the native provider configuration.
    public func loadIdentitySecret() throws -> Data {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        switch operations.copyMatching(query) {
        case let .success(data):
            try validateSecret(data)
            return data
        case .failure(errSecItemNotFound):
            throw MeshTunnelIdentityNsecStoreError.itemNotFound
        case .failure:
            throw MeshTunnelIdentityNsecStoreError.itemUnavailable
        }
    }

    /// Writes a valid secp256k1 scalar without ever deleting the existing item
    /// first. A failed write thus cannot turn an established device identity
    /// into a new identity at the next tunnel start.
    public func saveIdentitySecret(_ secret: Data) throws {
        try validateSecret(secret)
        let updateStatus = operations.update(
            baseQuery(),
            attributes: [
                kSecValueData as String: secret,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = secret
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = operations.add(addQuery)
            guard addStatus == errSecSuccess else {
                throw MeshTunnelIdentityNsecStoreError.itemUnavailable
            }
        default:
            throw MeshTunnelIdentityNsecStoreError.itemUnavailable
        }
    }

    public func deleteIdentitySecret() throws {
        let status = operations.delete(baseQuery())
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeshTunnelIdentityNsecStoreError.itemUnavailable
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The shared group is always explicit. It is never the default
            // group for unrelated host secrets.
            kSecAttrAccessGroup as String: accessGroup.value,
            // This identity is device-local; it must not participate in iCloud
            // Keychain synchronization or cross-device restore.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func validateSecret(_ secret: Data) throws {
        guard secret.count == 32,
              (try? P256K.Schnorr.PrivateKey(dataRepresentation: secret)) != nil
        else {
            throw MeshTunnelIdentityNsecStoreError.invalidIdentitySecret
        }
    }
}

public enum MeshTunnelIdentityNsecStoreError: Error, Equatable, Sendable {
    case accessGroupUnavailable
    case invalidAccessGroup
    case itemNotFound
    case itemUnavailable
    case invalidIdentitySecret
}

enum MeshTunnelKeychainReadResult: Sendable {
    case success(Data)
    case failure(OSStatus)
}

protocol MeshTunnelKeychainOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> MeshTunnelKeychainReadResult
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemMeshTunnelKeychainOperations: MeshTunnelKeychainOperating {
    func copyMatching(_ query: [String: Any]) -> MeshTunnelKeychainReadResult {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(status)
        }
        return .success(data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
