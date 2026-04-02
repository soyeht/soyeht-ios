import Foundation
import Security

// MARK: - Paired Server Model

struct PairedServer: Codable, Identifiable, Equatable {
    let id: String
    let host: String
    let name: String
    let role: String?
    let pairedAt: Date
    let expiresAt: String?
}

// MARK: - QR Scan Result

enum QRScanResult {
    case connect(token: String, host: String)
    case pair(token: String, host: String)
}

// MARK: - Session Store

final class SessionStore {
    static let shared = SessionStore()

    private let keychainService = "com.soyeht.mobile"
    private let keychainTokenKey = "session_token"
    private let keychainServerTokensKey = "server_tokens"
    private let defaults = UserDefaults.standard

    private enum Keys {
        // Legacy (single-server)
        static let apiHost = "soyeht.apiHost"
        static let sessionExpiry = "soyeht.sessionExpiry"
        static let cachedInstances = "soyeht.cachedInstances"
        // Multi-server
        static let pairedServers = "soyeht.pairedServers"
        static let activeServerId = "soyeht.activeServerId"
    }

    init() {
        migrateIfNeeded()
    }

    // MARK: - Multi-Server Storage

    var pairedServers: [PairedServer] {
        get {
            guard let data = defaults.data(forKey: Keys.pairedServers),
                  let servers = try? JSONDecoder().decode([PairedServer].self, from: data) else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.pairedServers)
            }
        }
    }

    var activeServerId: String? {
        get { defaults.string(forKey: Keys.activeServerId) }
        set { defaults.set(newValue, forKey: Keys.activeServerId) }
    }

    var activeServer: PairedServer? {
        guard let id = activeServerId else { return nil }
        return pairedServers.first(where: { $0.id == id })
    }

    func addServer(_ server: PairedServer, token: String) {
        var servers = pairedServers
        // Replace if same host already exists
        servers.removeAll(where: { $0.host == server.host })
        servers.append(server)
        pairedServers = servers
        saveTokenForServer(id: server.id, token: token)
    }

    func removeServer(id: String) {
        var servers = pairedServers
        servers.removeAll(where: { $0.id == id })
        pairedServers = servers
        removeTokenForServer(id: id)
        // Clear cached instances for this server
        defaults.removeObject(forKey: "soyeht.cachedInstances.\(id)")
        // If we removed the active server, clear the active selection
        if activeServerId == id {
            activeServerId = servers.first?.id
        }
    }

    func setActiveServer(id: String) {
        activeServerId = id
    }

    // MARK: - Backward-Compatible Session Access (THE KEY TRICK)

    var apiHost: String? {
        activeServer?.host ?? defaults.string(forKey: Keys.apiHost)
    }

    var sessionToken: String? {
        if let id = activeServerId, let token = tokenForServer(id: id) {
            return token
        }
        return loadFromKeychain(key: keychainTokenKey)
    }

    // MARK: - Legacy Session API (used by auth() for theyos://connect flow)

    func saveSession(token: String, host: String, expiresAt: String) {
        // If there's an active server matching this host, update its token
        if let active = activeServer, active.host == host {
            saveTokenForServer(id: active.id, token: token)
            return
        }
        // If any paired server matches this host, update that one
        if let existing = pairedServers.first(where: { $0.host == host }) {
            saveTokenForServer(id: existing.id, token: token)
            setActiveServer(id: existing.id)
            return
        }
        // Fallback: legacy single-server save (for theyos://connect with unknown host)
        saveToKeychain(key: keychainTokenKey, value: token)
        defaults.set(host, forKey: Keys.apiHost)
        defaults.set(expiresAt, forKey: Keys.sessionExpiry)
    }

    func loadSession() -> (token: String, host: String)? {
        if let server = activeServer, let token = tokenForServer(id: server.id) {
            return (token, server.host)
        }
        guard let token = loadFromKeychain(key: keychainTokenKey),
              let host = defaults.string(forKey: Keys.apiHost) else {
            return nil
        }
        return (token, host)
    }

    func clearSession() {
        // Clear active server's token only (not all servers)
        if let id = activeServerId {
            removeTokenForServer(id: id)
        } else {
            // Legacy fallback
            deleteFromKeychain(key: keychainTokenKey)
            defaults.removeObject(forKey: Keys.apiHost)
            defaults.removeObject(forKey: Keys.sessionExpiry)
            defaults.removeObject(forKey: Keys.cachedInstances)
        }
    }

    // MARK: - Cached Instances (per-server)

    func saveInstances(_ instances: [SoyehtInstance]) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        let key = instancesCacheKey
        defaults.set(data, forKey: key)
    }

    func loadInstances() -> [SoyehtInstance] {
        let key = instancesCacheKey
        guard let data = defaults.data(forKey: key),
              let instances = try? JSONDecoder().decode([SoyehtInstance].self, from: data) else {
            return []
        }
        return instances
    }

    private var instancesCacheKey: String {
        if let id = activeServerId {
            return "soyeht.cachedInstances.\(id)"
        }
        return Keys.cachedInstances
    }

    // MARK: - Migration from Single-Server to Multi-Server

    private func migrateIfNeeded() {
        guard pairedServers.isEmpty else { return }
        guard let host = defaults.string(forKey: Keys.apiHost),
              let token = loadFromKeychain(key: keychainTokenKey) else { return }

        let server = PairedServer(
            id: UUID().uuidString,
            host: host,
            name: host.components(separatedBy: ".").first ?? host,
            role: nil,
            pairedAt: Date(),
            expiresAt: defaults.string(forKey: Keys.sessionExpiry)
        )
        addServer(server, token: token)
        setActiveServer(id: server.id)
    }

    // MARK: - Server Token Keychain Helpers

    func tokenForServer(id: String) -> String? {
        loadServerTokens()[id]
    }

    private func saveTokenForServer(id: String, token: String) {
        var tokens = loadServerTokens()
        tokens[id] = token
        saveServerTokens(tokens)
    }

    private func removeTokenForServer(id: String) {
        var tokens = loadServerTokens()
        tokens.removeValue(forKey: id)
        saveServerTokens(tokens)
    }

    private func loadServerTokens() -> [String: String] {
        guard let json = loadFromKeychain(key: keychainServerTokensKey),
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveServerTokens(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else { return }
        saveToKeychain(key: keychainServerTokensKey, value: json)
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
