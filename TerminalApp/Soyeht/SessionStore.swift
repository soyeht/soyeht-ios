import Combine
import Foundation
import Security
import SoyehtCore

// MARK: - Paired Server + ServerContext
//
// Unified with SoyehtCore so both apps share one source of truth. Typealiases
// preserve the unqualified names used throughout the iOS target.

typealias PairedServer = SoyehtCore.PairedServer
typealias ServerContext = SoyehtCore.ServerContext

// MARK: - QR Scan Result

enum QRScanResult {
    case connect(token: String, host: String)
    case pair(token: String, host: String)
    case invite(token: String, host: String)

    /// Parse a theyos:// deep link URL into a scan result.
    static func from(url: URL) -> QRScanResult? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "theyos",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value else {
            return nil
        }
        switch components.host {
        case "pair": return .pair(token: token, host: host)
        case "connect": return .connect(token: token, host: host)
        case "invite": return .invite(token: token, host: host)
        default: return nil
        }
    }
}

// MARK: - Navigation State Restoration

struct NavigationState: Codable, Equatable {
    let serverId: String
    let instanceId: String
    let sessionName: String?
    let savedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(savedAt) > 24 * 60 * 60
    }

    /// Pure decision function — returns (instanceId, sessionName) if state is valid for the active server.
    static func resolve(
        state: NavigationState?,
        activeServerId: String?
    ) -> (instanceId: String, sessionName: String?)? {
        guard let state = state,
              !state.isExpired,
              state.serverId == activeServerId else { return nil }
        return (state.instanceId, state.sessionName)
    }
}

// MARK: - Session Store

final class SessionStore: ObservableObject {
    static let shared = SessionStore()
    private static let storageLock: NSRecursiveLock = {
        let lock = NSRecursiveLock()
        lock.name = "com.soyeht.mobile.SessionStore.storage"
        return lock
    }()

    /// Deep link URL received from the system, waiting to be processed by SoyehtAppView.
    @Published var pendingDeepLink: URL?

    private let keychainService: String
    private let keychainTokenKey = "session_token"
    private let keychainServerTokensKey = "server_tokens"
    private let defaults: UserDefaults

    private func withStorageLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return try body()
    }

    private enum Keys {
        // Legacy (single-server)
        static let apiHost = "soyeht.apiHost"
        static let sessionExpiry = "soyeht.sessionExpiry"
        static let cachedInstances = "soyeht.cachedInstances"
        // Multi-server
        static let pairedServers = "soyeht.pairedServers"
        static let activeServerId = "soyeht.activeServerId"
        static let localCommanderClaims = "soyeht.localCommanderClaims"
        static let navigationState = "soyeht.navigationState"
    }

    init(defaults: UserDefaults = .standard, keychainService: String = "com.soyeht.mobile") {
        self.defaults = defaults
        self.keychainService = keychainService
        migrateIfNeeded()
    }

    // MARK: - Multi-Server Storage

    var pairedServers: [PairedServer] {
        get {
            withStorageLock {
                guard let data = defaults.data(forKey: Keys.pairedServers),
                      let servers = try? JSONDecoder().decode([PairedServer].self, from: data) else {
                    return []
                }
                return servers
            }
        }
        set {
            withStorageLock {
                if let data = try? JSONEncoder().encode(newValue) {
                    defaults.set(data, forKey: Keys.pairedServers)
                }
            }
        }
    }

    var activeServerId: String? {
        get { withStorageLock { defaults.string(forKey: Keys.activeServerId) } }
        set { withStorageLock { defaults.set(newValue, forKey: Keys.activeServerId) } }
    }

    var activeServer: PairedServer? {
        withStorageLock {
            guard let id = activeServerId else { return nil }
            return pairedServers.first(where: { $0.id == id })
        }
    }

    func addServer(_ server: PairedServer, token: String) {
        withStorageLock {
            var servers = pairedServers
            // Replace if same host already exists
            servers.removeAll(where: { $0.host == server.host })
            servers.append(server)
            pairedServers = servers
            saveTokenForServer(id: server.id, token: token)
        }
    }

    func removeServer(id: String) {
        withStorageLock {
            var servers = pairedServers
            servers.removeAll(where: { $0.id == id })
            pairedServers = servers
            removeTokenForServer(id: id)
            removeLocalCommanderClaims(serverKey: id)
            if let nav = loadNavigationState(), nav.serverId == id {
                clearNavigationState()
            }
            // Clear cached instances for this server
            defaults.removeObject(forKey: "soyeht.cachedInstances.\(id)")
            // If we removed the active server, clear the active selection
            if activeServerId == id {
                activeServerId = servers.first?.id
            }
        }
    }

    func setActiveServer(id: String) {
        withStorageLock {
            activeServerId = id
        }
    }

    /// Build the `(server, token)` pair needed to route an API call to a
    /// specific paired server. Returns nil if the server is no longer
    /// paired or has no token in the keychain. Prefer this over reading
    /// `apiHost` / `sessionToken`, which are active-server-scoped.
    func context(for serverId: String) -> ServerContext? {
        withStorageLock {
            guard let server = pairedServers.first(where: { $0.id == serverId }),
                  let token = tokenForServer(id: serverId) else {
                return nil
            }
            return ServerContext(server: server, token: token)
        }
    }

    // MARK: - Backward-Compatible Session Access (THE KEY TRICK)

    var apiHost: String? {
        withStorageLock {
            #if DEBUG
            if let override = defaults.string(forKey: "soyeht.debug.hostOverride"),
               !override.isEmpty {
                return override
            }
            #endif
            return activeServer?.host ?? defaults.string(forKey: Keys.apiHost)
        }
    }

    var sessionToken: String? {
        withStorageLock {
            #if DEBUG
            if let override = defaults.string(forKey: "soyeht.debug.sessionTokenOverride"),
               !override.isEmpty {
                return override
            }
            #endif
            if let id = activeServerId, let token = tokenForServer(id: id) {
                return token
            }
            return loadFromKeychain(key: keychainTokenKey)
        }
    }

    // MARK: - Legacy Session API (used by auth() for theyos://connect flow)

    func saveSession(token: String, host: String, expiresAt: String) {
        withStorageLock {
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
    }

    func loadSession() -> (token: String, host: String)? {
        withStorageLock {
            if let server = activeServer, let token = tokenForServer(id: server.id) {
                return (token, server.host)
            }
            guard let token = loadFromKeychain(key: keychainTokenKey),
                  let host = defaults.string(forKey: Keys.apiHost) else {
                return nil
            }
            return (token, host)
        }
    }

    func clearSession() {
        withStorageLock {
            // Clear active server's token only (not all servers)
            if let id = activeServerId {
                removeTokenForServer(id: id)
                removeLocalCommanderClaims(serverKey: id)
            } else {
                // Legacy fallback
                deleteFromKeychain(key: keychainTokenKey)
                if let host = defaults.string(forKey: Keys.apiHost) {
                    removeLocalCommanderClaims(serverKey: host)
                }
                defaults.removeObject(forKey: Keys.apiHost)
                defaults.removeObject(forKey: Keys.sessionExpiry)
                defaults.removeObject(forKey: Keys.cachedInstances)
            }
            clearNavigationState()
        }
    }

    // MARK: - Cached Instances (per-server)
    //
    // Every paired server has its own `soyeht.cachedInstances.<serverId>`
    // entry so cold-start rendering is self-consistent: unreachable servers
    // still show their last-known claws stamped with the right server name,
    // and no cross-server mixing can happen. Callers must pass an explicit
    // serverId — there is no fallback to the active server.

    func saveInstances(_ instances: [SoyehtInstance], serverId: String) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: instancesCacheKey(serverId: serverId))
    }

    func loadInstances(serverId: String) -> [SoyehtInstance] {
        guard let data = defaults.data(forKey: instancesCacheKey(serverId: serverId)),
              let instances = try? JSONDecoder().decode([SoyehtInstance].self, from: data) else {
            return []
        }
        return instances
    }

    private func instancesCacheKey(serverId: String) -> String {
        "soyeht.cachedInstances.\(serverId)"
    }

    /// Search every paired server's cache for an instance with the given id.
    /// Used by deep-link handling (e.g. `theyos://instance/<id>` from a Live
    /// Activity widget) where the owning server isn't in the URL payload.
    /// Returns the first match; two servers with colliding instance ids are
    /// already disambiguated at the list level via `InstanceEntry`, so this
    /// is best-effort for the restoration path only.
    func findCachedInstance(id: String) -> (instance: SoyehtInstance, serverId: String)? {
        for server in pairedServers {
            if let match = loadInstances(serverId: server.id).first(where: { $0.id == id }) {
                return (match, server.id)
            }
        }
        return nil
    }

    // MARK: - Navigation State Restoration

    func saveNavigationState(_ state: NavigationState) {
        withStorageLock {
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: Keys.navigationState)
            }
        }
    }

    func loadNavigationState() -> NavigationState? {
        withStorageLock {
            guard let data = defaults.data(forKey: Keys.navigationState),
                  let state = try? JSONDecoder().decode(NavigationState.self, from: data),
                  !state.isExpired else { return nil }
            return state
        }
    }

    func clearNavigationState() {
        withStorageLock {
            defaults.removeObject(forKey: Keys.navigationState)
        }
    }

    // MARK: - Local Commander Claims

    func hasLocalCommanderClaim(container: String, session: String) -> Bool {
        withStorageLock {
            loadLocalCommanderClaims().contains(workspaceKey(container: container, session: session))
        }
    }

    func markLocalCommander(container: String, session: String) {
        withStorageLock {
            var claims = loadLocalCommanderClaims()
            claims.insert(workspaceKey(container: container, session: session))
            saveLocalCommanderClaims(claims)
        }
    }

    func clearLocalCommander(container: String, session: String) {
        withStorageLock {
            var claims = loadLocalCommanderClaims()
            claims.remove(workspaceKey(container: container, session: session))
            saveLocalCommanderClaims(claims)
        }
    }

    // MARK: - Migration from Single-Server to Multi-Server

    private func migrateIfNeeded() {
        withStorageLock {
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
    }

    private func workspaceKey(container: String, session: String) -> String {
        let serverKey = activeServerId ?? apiHost ?? "default"
        return "\(serverKey)::\(container)::\(session)"
    }

    private func loadLocalCommanderClaims() -> Set<String> {
        withStorageLock {
            let claims = defaults.stringArray(forKey: Keys.localCommanderClaims) ?? []
            return Set(claims)
        }
    }

    private func saveLocalCommanderClaims(_ claims: Set<String>) {
        withStorageLock {
            defaults.set(Array(claims).sorted(), forKey: Keys.localCommanderClaims)
        }
    }

    private func removeLocalCommanderClaims(serverKey: String) {
        let filteredClaims = loadLocalCommanderClaims().filter { !$0.hasPrefix("\(serverKey)::") }
        saveLocalCommanderClaims(Set(filteredClaims))
    }

    // MARK: - Server Token Keychain Helpers

    func tokenForServer(id: String) -> String? {
        withStorageLock {
            loadServerTokens()[id]
        }
    }

    private func saveTokenForServer(id: String, token: String) {
        withStorageLock {
            var tokens = loadServerTokens()
            tokens[id] = token
            saveServerTokens(tokens)
        }
    }

    private func removeTokenForServer(id: String) {
        withStorageLock {
            var tokens = loadServerTokens()
            tokens.removeValue(forKey: id)
            saveServerTokens(tokens)
        }
    }

    private func loadServerTokens() -> [String: String] {
        withStorageLock {
            guard let json = loadFromKeychain(key: keychainServerTokensKey),
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
    }

    private func saveServerTokens(_ tokens: [String: String]) {
        withStorageLock {
            guard let data = try? JSONEncoder().encode(tokens),
                  let json = String(data: data, encoding: .utf8) else { return }
            saveToKeychain(key: keychainServerTokensKey, value: json)
        }
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        withStorageLock {
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
    }

    private func loadFromKeychain(key: String) -> String? {
        withStorageLock {
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
    }

    private func deleteFromKeychain(key: String) {
        withStorageLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
