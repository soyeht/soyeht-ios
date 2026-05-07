import Foundation
import SoyehtCore

enum APNSRegistrationError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAck
    case missingAckVersion
    case unsupportedAckVersion(UInt64)
    case missingUpdatedAt
    case ownerIdentityUnavailable
}

struct APNSRegistrationAck: Equatable, Sendable {
    let updatedAt: UInt64

    init(updatedAt: UInt64) {
        self.updatedAt = updatedAt
    }

    init(cbor data: Data) throws {
        guard case .map(let map) = try HouseholdCBOR.decode(data) else {
            throw APNSRegistrationError.invalidAck
        }
        guard case .unsigned(let version) = map["v"] else {
            throw APNSRegistrationError.missingAckVersion
        }
        guard version == 1 else {
            throw APNSRegistrationError.unsupportedAckVersion(version)
        }
        guard case .unsigned(let updatedAt) = map["updated_at"] else {
            throw APNSRegistrationError.missingUpdatedAt
        }
        self.updatedAt = updatedAt
    }
}

struct APNSRegistrationRequest: Equatable, Sendable {
    let method: String
    let url: URL
    let pathAndQuery: String
    let body: Data
    let authorizationHeader: String
    let householdId: String
    let tokenHash: Data
}

struct APNSRegistrationState: Codable, Equatable, Sendable {
    let householdId: String
    let tokenHash: Data
    let registeredAt: Date
    let serverUpdatedAt: UInt64
}

protocol APNSRegistrationStateStoring: Sendable {
    func load() -> APNSRegistrationState?
    func save(_ state: APNSRegistrationState)
    func clear()
}

enum HouseholdApplePushPreference {
    private static let keyPrefix = "soyeht.household.applePushService.enabled"

    static func isEnabled(
        for householdId: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = storageKey(for: householdId)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        for householdId: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(isEnabled, forKey: storageKey(for: householdId))
        NotificationCenter.default.post(
            name: .soyehtHouseholdApplePushPreferenceChanged,
            object: householdId
        )
    }

    private static func storageKey(for householdId: String) -> String {
        "\(keyPrefix).\(householdId)"
    }
}

extension Notification.Name {
    static let soyehtHouseholdApplePushPreferenceChanged = Notification.Name("soyeht.household.applePush.preferenceChanged")
}

final class UserDefaultsAPNSRegistrationStateStore: APNSRegistrationStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "soyeht.household.apns.registrationState"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> APNSRegistrationState? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(APNSRegistrationState.self, from: data)
    }

    func save(_ state: APNSRegistrationState) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}

actor APNSRegistrationCoordinator {
    typealias SessionProvider = @Sendable () throws -> ActiveHouseholdState?
    typealias AuthorizationProvider = @Sendable (
        _ session: ActiveHouseholdState,
        _ method: String,
        _ pathAndQuery: String,
        _ body: Data
    ) throws -> String
    typealias Transport = @Sendable (APNSRegistrationRequest) async throws -> APNSRegistrationAck
    typealias NowProvider = @Sendable () -> Date
    typealias EnabledProvider = @Sendable (ActiveHouseholdState) -> Bool

    static let registrationPath = "/api/v1/household/owner-device/push-token"
    static let staleAfter: TimeInterval = 24 * 60 * 60
    static let shared = APNSRegistrationCoordinator.production()

    private let sessionProvider: SessionProvider
    private let authorizationProvider: AuthorizationProvider
    private let transport: Transport
    private let stateStore: APNSRegistrationStateStoring
    private let nowProvider: NowProvider
    private let enabledProvider: EnabledProvider
    private let staleAfter: TimeInterval

    private var latestDeviceToken: Data?
    private var registrationInFlight = false
    private var shouldRetryAfterInFlight = false
    private var unknownTokenReported = false
    private var suspended = false

    init(
        sessionProvider: @escaping SessionProvider,
        authorizationProvider: @escaping AuthorizationProvider,
        transport: @escaping Transport,
        stateStore: APNSRegistrationStateStoring = UserDefaultsAPNSRegistrationStateStore(),
        nowProvider: @escaping NowProvider = { Date() },
        enabledProvider: @escaping EnabledProvider = { _ in true },
        staleAfter: TimeInterval = APNSRegistrationCoordinator.staleAfter
    ) {
        self.sessionProvider = sessionProvider
        self.authorizationProvider = authorizationProvider
        self.transport = transport
        self.stateStore = stateStore
        self.nowProvider = nowProvider
        self.enabledProvider = enabledProvider
        self.staleAfter = staleAfter
    }

    func receiveDeviceToken(_ token: Data) async throws -> Bool {
        latestDeviceToken = token
        return try await registerIfNeeded()
    }

    func handleSessionActivated() async throws -> Bool {
        try await registerIfNeeded()
    }

    func handleForeground() async throws -> Bool {
        try await registerIfNeeded()
    }

    func clearSession() {
        stateStore.clear()
        unknownTokenReported = false
        shouldRetryAfterInFlight = false
    }

    func markTokenUnknown() {
        stateStore.clear()
        unknownTokenReported = true
    }

    func suspend() {
        suspended = true
        stateStore.clear()
        unknownTokenReported = false
        shouldRetryAfterInFlight = false
    }

    func resume() async throws -> Bool {
        suspended = false
        return try await registerIfNeeded()
    }

    private func registerIfNeeded() async throws -> Bool {
        guard !suspended else { return false }
        guard let token = latestDeviceToken else { return false }
        guard let session = try sessionProvider() else { return false }
        guard enabledProvider(session) else { return false }

        if registrationInFlight {
            shouldRetryAfterInFlight = true
            return false
        }

        let tokenHash = Self.tokenHash(token)
        let now = nowProvider()
        if !unknownTokenReported,
           let state = stateStore.load(),
           state.householdId == session.householdId,
           state.tokenHash == tokenHash,
           now.timeIntervalSince(state.registeredAt) < staleAfter {
            return false
        }

        registrationInFlight = true
        shouldRetryAfterInFlight = false
        defer { registrationInFlight = false }

        let request = try makeRequest(session: session, token: token, tokenHash: tokenHash)
        let ack = try await transport(request)

        if !suspended,
           enabledProvider(session),
           latestDeviceToken.map(Self.tokenHash) == tokenHash {
            stateStore.save(APNSRegistrationState(
                householdId: session.householdId,
                tokenHash: tokenHash,
                registeredAt: nowProvider(),
                serverUpdatedAt: ack.updatedAt
            ))
            unknownTokenReported = false
        } else {
            shouldRetryAfterInFlight = true
        }

        if shouldRetryAfterInFlight {
            shouldRetryAfterInFlight = false
            _ = try await registerIfNeeded()
        }
        return true
    }

    private func makeRequest(
        session: ActiveHouseholdState,
        token: Data,
        tokenHash: Data
    ) throws -> APNSRegistrationRequest {
        let body = Self.registrationBody(deviceToken: token)
        guard let url = Self.registrationURL(endpoint: session.endpoint) else {
            throw APNSRegistrationError.invalidEndpoint
        }
        let pathAndQuery = Self.pathAndQuery(for: url)
        let authorization = try authorizationProvider(session, "POST", pathAndQuery, body)
        return APNSRegistrationRequest(
            method: "POST",
            url: url,
            pathAndQuery: pathAndQuery,
            body: body,
            authorizationHeader: authorization,
            householdId: session.householdId,
            tokenHash: tokenHash
        )
    }

    static func registrationBody(deviceToken: Data) -> Data {
        HouseholdCBOR.encode(.map([
            "platform": .text("ios"),
            "push_token": .bytes(deviceToken),
            "v": .unsigned(1),
        ]))
    }

    static func tokenHash(_ token: Data) -> Data {
        HouseholdHash.blake3(token)
    }

    static func registrationURL(endpoint: URL) -> URL? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.percentEncodedPath = basePath.isEmpty ? registrationPath : "/\(basePath)\(registrationPath)"
        components?.percentEncodedQuery = nil
        components?.fragment = nil
        return components?.url
    }

    static func pathAndQuery(for url: URL) -> String {
        var pathAndQuery = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            pathAndQuery += "?\(query)"
        }
        return pathAndQuery
    }

    private static func production() -> APNSRegistrationCoordinator {
        let householdStore = HouseholdSessionStore()
        let keyProvider = SecureEnclaveOwnerIdentityKeyProvider()
        let nowProvider: NowProvider = { Date() }
        let wireClient = Phase3WireClient()

        return APNSRegistrationCoordinator(
            sessionProvider: {
                try householdStore.load()
            },
            authorizationProvider: { session, method, pathAndQuery, body in
                let ownerIdentity: any OwnerIdentitySigning
                do {
                    ownerIdentity = try keyProvider.loadOwnerIdentity(
                        keyReference: session.ownerKeyReference,
                        publicKey: session.ownerPublicKey
                    )
                } catch {
                    throw APNSRegistrationError.ownerIdentityUnavailable
                }
                return try HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: nowProvider)
                    .authorization(method: method, pathAndQuery: pathAndQuery, body: body)
                    .authorizationHeader
            },
            transport: { request in
                let response = try await wireClient.send(
                    method: request.method,
                    url: request.url,
                    body: request.body,
                    additionalHeaders: ["Authorization": request.authorizationHeader]
                )
                return try APNSRegistrationAck(cbor: response)
            },
            nowProvider: nowProvider,
            enabledProvider: { session in
                HouseholdApplePushPreference.isEnabled(for: session.householdId)
            }
        )
    }
}
