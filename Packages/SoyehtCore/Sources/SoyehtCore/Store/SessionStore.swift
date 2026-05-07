import Combine
import Foundation
import Security
import os

private let sessionStoreLogger = Logger(subsystem: "com.soyeht.mobile", category: "session-store")

// MARK: - Paired Server Model

public struct PairedServer: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let host: String
    public let name: String
    public let role: String?
    public let pairedAt: Date
    public let expiresAt: String?

    public init(id: String, host: String, name: String, role: String?, pairedAt: Date, expiresAt: String?) {
        self.id = id
        self.host = host
        self.name = name
        self.role = role
        self.pairedAt = pairedAt
        self.expiresAt = expiresAt
    }
}

// MARK: - QR Scan Result

public enum QRScanResult {
    case connect(token: String, host: String)
    case pair(token: String, host: String)
    case invite(token: String, host: String)
    case householdPairDevice(url: URL)
    case householdPairMachine(envelope: JoinRequestEnvelope)

    public static func from(url: URL) -> QRScanResult? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme == "soyeht",
           components.host == "household",
           components.path == "/pair-device" {
            return .householdPairDevice(url: url)
        }

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

public struct NavigationState: Codable, Equatable, Sendable {
    public let serverId: String
    public let instanceId: String
    public let sessionName: String?
    public let savedAt: Date

    public var isExpired: Bool {
        Date().timeIntervalSince(savedAt) > 24 * 60 * 60
    }

    public init(serverId: String, instanceId: String, sessionName: String?, savedAt: Date) {
        self.serverId = serverId
        self.instanceId = instanceId
        self.sessionName = sessionName
        self.savedAt = savedAt
    }

    public static func resolve(
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

public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()
    private static let storageLock: NSRecursiveLock = {
        let lock = NSRecursiveLock()
        lock.name = "com.soyeht.mobile.SessionStore.storage"
        return lock
    }()

    @Published public var pendingDeepLink: URL?

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
        static let apiHost = "soyeht.apiHost"
        static let sessionExpiry = "soyeht.sessionExpiry"
        static let cachedInstances = "soyeht.cachedInstances"
        static let pairedServers = "soyeht.pairedServers"
        static let activeServerId = "soyeht.activeServerId"
        static let localCommanderClaims = "soyeht.localCommanderClaims"
        static let navigationState = "soyeht.navigationState"
    }

    public init(defaults: UserDefaults = .standard, keychainService: String = "com.soyeht.mobile") {
        self.defaults = defaults
        self.keychainService = keychainService
        migrateIfNeeded()
    }

    // MARK: - Multi-Server Storage

    public var pairedServers: [PairedServer] {
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

    public var activeServerId: String? {
        get { withStorageLock { defaults.string(forKey: Keys.activeServerId) } }
        set { withStorageLock { defaults.set(newValue, forKey: Keys.activeServerId) } }
    }

    public var activeServer: PairedServer? {
        withStorageLock {
            guard let id = activeServerId else { return nil }
            return pairedServers.first(where: { $0.id == id })
        }
    }

    public func addServer(_ server: PairedServer, token: String) {
        withStorageLock {
            var servers = pairedServers
            servers.removeAll(where: { $0.host == server.host })
            servers.append(server)
            pairedServers = servers
            saveTokenForServer(id: server.id, token: token)
        }
    }

    public func removeServer(id: String) {
        withStorageLock {
            var servers = pairedServers
            servers.removeAll(where: { $0.id == id })
            pairedServers = servers
            removeTokenForServer(id: id)
            removeLocalCommanderClaims(serverKey: id)
            if let nav = loadNavigationState(), nav.serverId == id {
                clearNavigationState()
            }
            defaults.removeObject(forKey: "soyeht.cachedInstances.\(id)")
            if activeServerId == id {
                activeServerId = servers.first?.id
            }
        }
    }

    public func setActiveServer(id: String) {
        withStorageLock {
            activeServerId = id
        }
        NotificationCenter.default.post(name: ClawStoreNotifications.activeServerChanged, object: nil)
    }

    // MARK: - ServerContext

    /// Build the `(server, token)` pair needed to route an API call to a
    /// specific paired server. Returns nil if the server is no longer
    /// paired or has no token. Prefer this over reading `apiHost` /
    /// `sessionToken`, which are active-server-scoped.
    public func context(for serverId: String) -> ServerContext? {
        withStorageLock {
            guard let server = pairedServers.first(where: { $0.id == serverId }),
                  let token = tokenForServer(id: serverId) else {
                return nil
            }
            return ServerContext(server: server, token: token)
        }
    }

    /// Convenience: the context for the active server. Nil if nothing paired
    /// or if the active server's token was evicted.
    public func currentContext() -> ServerContext? {
        withStorageLock {
            guard let id = activeServerId else { return nil }
            return context(for: id)
        }
    }

    // MARK: - Active Household

    public func activeHouseholdState(
        using householdStore: HouseholdSessionStore = HouseholdSessionStore()
    ) throws -> ActiveHouseholdState? {
        try householdStore.load()
    }

    public func validatedActiveHousehold(
        requiredOperation: String? = nil,
        using householdStore: HouseholdSessionStore = HouseholdSessionStore(),
        now: Date = Date()
    ) throws -> ActiveHouseholdState {
        guard let household = try householdStore.load() else {
            throw HouseholdPoPError.noActiveHousehold
        }
        do {
            try household.personCert.validate(
                householdId: household.householdId,
                householdPublicKey: household.householdPublicKey,
                ownerPersonId: household.ownerPersonId,
                ownerPersonPublicKey: household.ownerPublicKey,
                now: now
            )
        } catch {
            throw HouseholdPoPError.invalidLocalCert
        }
        if let requiredOperation, !household.personCert.allows(requiredOperation) {
            throw HouseholdPoPError.missingCaveat(requiredOperation)
        }
        return household
    }

    // MARK: - Session Access

    public var apiHost: String? {
        withStorageLock {
            #if DEBUG && os(iOS)
            if let override = defaults.string(forKey: "soyeht.debug.hostOverride"),
               !override.isEmpty {
                return override
            }
            #endif
            return activeServer?.host ?? defaults.string(forKey: Keys.apiHost)
        }
    }

    public var sessionToken: String? {
        withStorageLock {
            #if DEBUG && os(iOS)
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

    public func saveSession(token: String, host: String, expiresAt: String) {
        withStorageLock {
            if let active = activeServer, active.host == host {
                saveTokenForServer(id: active.id, token: token)
                return
            }
            if let existing = pairedServers.first(where: { $0.host == host }) {
                saveTokenForServer(id: existing.id, token: token)
                setActiveServer(id: existing.id)
                return
            }
            saveToKeychain(key: keychainTokenKey, value: token)
            defaults.set(host, forKey: Keys.apiHost)
            defaults.set(expiresAt, forKey: Keys.sessionExpiry)
        }
    }

    public func loadSession() -> (token: String, host: String)? {
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

    public func clearSession() {
        withStorageLock {
            if let id = activeServerId {
                removeTokenForServer(id: id)
                removeLocalCommanderClaims(serverKey: id)
            } else {
                // No active server — wipe both the legacy single-token
                // (`keychainTokenKey`) and the multi-server map so a stale
                // entry from either path cannot survive a sign-out.
                deleteFromKeychain(key: keychainTokenKey)
                saveServerTokens([:])
                if let host = defaults.string(forKey: Keys.apiHost) {
                    removeLocalCommanderClaims(serverKey: host)
                }
                defaults.removeObject(forKey: Keys.apiHost)
                defaults.removeObject(forKey: Keys.sessionExpiry)
                defaults.removeObject(forKey: Keys.cachedInstances)
            }
            // DEBUG-only overrides are read by `apiHost` / `sessionToken`
            // before falling back to the regular store. A persisted override
            // that survives sign-out would silently route the next session
            // through the wrong host or with a stale bearer. Clear them
            // here so signOut produces a truly empty state. The keys are
            // listed inline (not as constants) so the cleanup is greppable
            // alongside the read sites that consult them.
            defaults.removeObject(forKey: "soyeht.debug.hostOverride")
            defaults.removeObject(forKey: "soyeht.debug.sessionTokenOverride")
            defaults.removeObject(forKey: "soyeht.debug.autoOpenFileBrowser")
            clearNavigationState()
        }
    }

    // MARK: - Cached Instances

    /// Persist instances pinned to a specific server id. The key is derived
    /// from the supplied id, NOT from `activeServerId` at write-time, so a
    /// concurrent `setActiveServer(id:)` cannot redirect the write to the
    /// wrong server's cache.
    public func saveInstances(_ instances: [SoyehtInstance], serverId: String) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: Self.instancesCacheKey(forServerId: serverId))
    }

    /// Read instances cached for the currently active server. Reads are not
    /// racy in a corrupting way — they return whatever is currently active.
    public func loadInstances() -> [SoyehtInstance] {
        let key: String
        if let id = activeServerId {
            key = Self.instancesCacheKey(forServerId: id)
        } else {
            key = Keys.cachedInstances
        }
        return loadInstances(cacheKey: key)
    }

    /// Read instances cached for a specific paired server. iOS renders a
    /// merged multi-server list, so callers must be able to read each server's
    /// cache without mutating `activeServerId`.
    public func loadInstances(serverId: String) -> [SoyehtInstance] {
        loadInstances(cacheKey: Self.instancesCacheKey(forServerId: serverId))
    }

    /// Search every paired server's cache for an instance with the given id.
    /// This is best-effort restoration for deep links that carry only an
    /// instance id and not its owning server id.
    public func findCachedInstance(id: String) -> (instance: SoyehtInstance, serverId: String)? {
        for server in pairedServers {
            if let match = loadInstances(serverId: server.id).first(where: { $0.id == id }) {
                return (match, server.id)
            }
        }
        return nil
    }

    private func loadInstances(cacheKey key: String) -> [SoyehtInstance] {
        guard let data = defaults.data(forKey: key),
              let instances = try? JSONDecoder().decode([SoyehtInstance].self, from: data) else {
            return []
        }
        return instances
    }

    private static func instancesCacheKey(forServerId id: String) -> String {
        "soyeht.cachedInstances.\(id)"
    }

    // MARK: - Navigation State

    public func saveNavigationState(_ state: NavigationState) {
        withStorageLock {
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: Keys.navigationState)
            }
        }
    }

    public func loadNavigationState() -> NavigationState? {
        withStorageLock {
            guard let data = defaults.data(forKey: Keys.navigationState),
                  let state = try? JSONDecoder().decode(NavigationState.self, from: data),
                  !state.isExpired else { return nil }
            return state
        }
    }

    public func clearNavigationState() {
        withStorageLock {
            defaults.removeObject(forKey: Keys.navigationState)
        }
    }

    // MARK: - Local Commander Claims

    public func hasLocalCommanderClaim(container: String, session: String) -> Bool {
        withStorageLock {
            loadLocalCommanderClaims().contains(workspaceKey(container: container, session: session))
        }
    }

    public func markLocalCommander(container: String, session: String) {
        withStorageLock {
            var claims = loadLocalCommanderClaims()
            claims.insert(workspaceKey(container: container, session: session))
            saveLocalCommanderClaims(claims)
        }
    }

    public func clearLocalCommander(container: String, session: String) {
        withStorageLock {
            var claims = loadLocalCommanderClaims()
            claims.remove(workspaceKey(container: container, session: session))
            saveLocalCommanderClaims(claims)
        }
    }

    // MARK: - Token Access

    public func tokenForServer(id: String) -> String? {
        withStorageLock {
            loadServerTokens()[id]
        }
    }

    // MARK: - Migration

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
            #if os(macOS) && DEBUG
            // Ad-hoc signed dev builds trigger a per-binary keychain ACL
            // prompt on every launch (different signature → different ACL
            // owner), which makes iteration painful. DEBUG persists the
            // server-token map in UserDefaults instead. Release builds are
            // properly signed/notarized and have no such prompt — they go
            // through the Keychain branch below.
            //
            // Release does NOT consult UserDefaults: macOS Debug uses bundle
            // id `com.soyeht.mac.dev` and Release uses `com.soyeht.mac`, so
            // the two builds have separate UserDefaults domains anyway —
            // there is nothing to "fall through" to. The shared persistence
            // surface is the Keychain service (`com.soyeht.mobile`), which
            // both configurations use.
            guard let data = defaults.data(forKey: "soyeht.serverTokens"),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
            #else
            guard let json = loadFromKeychain(key: keychainServerTokensKey),
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
            #endif
        }
    }

    private func saveServerTokens(_ tokens: [String: String]) {
        withStorageLock {
            // Empty dict → wipe the row entirely instead of leaving an empty
            // "{}" sitting in storage. This matters for Release because a
            // stale Keychain row would survive `signOut` from a no-active-
            // server state until the next pair, and for DEBUG because it
            // keeps the plist clean during dev iteration.
            if tokens.isEmpty {
                #if os(macOS) && DEBUG
                defaults.removeObject(forKey: "soyeht.serverTokens")
                #else
                deleteFromKeychain(key: keychainServerTokensKey)
                #endif
                return
            }
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            #if os(macOS) && DEBUG
            defaults.set(data, forKey: "soyeht.serverTokens")
            #else
            guard let json = String(data: data, encoding: .utf8) else { return }
            saveToKeychain(key: keychainServerTokensKey, value: json)
            #endif
        }
    }

    // MARK: - Keychain Helpers

    private func keychainBaseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
    }

    private func saveToKeychain(key: String, value: String) {
        withStorageLock {
            guard let data = value.data(using: .utf8) else { return }
            let baseQuery = keychainBaseQuery(key: key)
            // Atomic update path: SecItemUpdate replaces the value in a single
            // call, so a crash or termination cannot leave the keychain with
            // the row deleted but not yet re-added (the previous Delete +
            // Add pattern lost tokens on abrupt exit). Falls back to Add only
            // when the row truly does not exist.
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                updateAttributes as CFDictionary
            )
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                if addStatus != errSecSuccess {
                    sessionStoreLogger.error(
                        "Keychain SecItemAdd failed key=\(key, privacy: .public) status=\(addStatus)"
                    )
                }
            default:
                sessionStoreLogger.error(
                    "Keychain SecItemUpdate failed key=\(key, privacy: .public) status=\(updateStatus)"
                )
            }
        }
    }

    private func loadFromKeychain(key: String) -> String? {
        withStorageLock {
            var query = keychainBaseQuery(key: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func deleteFromKeychain(key: String) {
        withStorageLock {
            let query = keychainBaseQuery(key: key)
            SecItemDelete(query as CFDictionary)
        }
    }
}
