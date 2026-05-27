import Combine
import Foundation
import SoyehtCore

/// UI-facing gate for macOS guest-image readiness.
///
/// Linux servers do not need a guest image, so they are always allowed.
/// Mac servers must report `GuestImageReadiness.ready` before iOS exposes
/// Claw install/deploy actions. The state is intentionally local to Claw
/// Store UI; PR-5B does not persist readiness into `ServerRegistry`.
enum GuestImageReadinessGateState: Equatable, Sendable {
    case allowed(GuestImageReadiness)
    case blocked(GuestImageReadiness)
    case checking
    case unavailable

    var allowsInstall: Bool {
        switch self {
        case .allowed:
            return true
        case .blocked, .checking, .unavailable:
            return false
        }
    }

    var needsPolling: Bool {
        switch self {
        case .checking, .blocked:
            return true
        case .allowed, .unavailable:
            return false
        }
    }

    var readiness: GuestImageReadiness? {
        switch self {
        case .allowed(let readiness), .blocked(let readiness):
            return readiness
        case .checking, .unavailable:
            return nil
        }
    }

    static func from(_ readiness: GuestImageReadiness) -> GuestImageReadinessGateState {
        readiness.allowsInstall ? .allowed(readiness) : .blocked(readiness)
    }
}

@MainActor
final class GuestImageReadinessClient {
    typealias FetchStatus = @Sendable (URL) async throws -> BootstrapStatusResponse

    static let shared = GuestImageReadinessClient()

    private struct CacheEntry {
        let state: GuestImageReadinessGateState
        let storedAt: Date
    }

    private let ttl: TimeInterval
    private let fetchStatus: FetchStatus
    private var cache: [String: CacheEntry] = [:]

    init(
        ttl: TimeInterval = 5,
        fetchStatus: @escaping FetchStatus = { baseURL in
            try await BootstrapStatusClient(baseURL: baseURL).fetch()
        }
    ) {
        self.ttl = ttl
        self.fetchStatus = fetchStatus
    }

    func state(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry,
        now: Date = Date()
    ) async -> GuestImageReadinessGateState {
        let initial = Self.initialState(for: target, resolution: resolution, registry: registry)
        guard case .checking = initial else { return initial }

        if let entry = cache[target.serverID], now.timeIntervalSince(entry.storedAt) < ttl {
            return entry.state
        }

        guard let baseURL = Self.bootstrapBaseURL(for: target, resolution: resolution, registry: registry) else {
            let state: GuestImageReadinessGateState = .unavailable
            cache[target.serverID] = CacheEntry(state: state, storedAt: now)
            return state
        }

        do {
            let status = try await fetchStatus(baseURL)
            let state = GuestImageReadinessGateState.from(status.guestImageReadiness)
            cache[target.serverID] = CacheEntry(state: state, storedAt: now)
            return state
        } catch {
            let state: GuestImageReadinessGateState = .unavailable
            cache[target.serverID] = CacheEntry(state: state, storedAt: now)
            return state
        }
    }

    func state(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        now: Date = Date()
    ) async -> GuestImageReadinessGateState {
        await state(for: target, resolution: resolution, registry: .shared, now: now)
    }

    func clearCache() {
        cache.removeAll()
    }

    static func initialState(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry
    ) -> GuestImageReadinessGateState {
        if case .unavailable = resolution {
            return .unavailable
        }

        if let server = registry.server(id: target.serverID) {
            switch server.kind {
            case .linux:
                return .allowed(.notApplicable)
            case .mac:
                return .checking
            }
        }

        switch resolution {
        case .server(let context):
            return context.server.kind == .adminHost ? .allowed(.notApplicable) : .checking
        case .householdEndpoint:
            return .checking
        case .unavailable:
            return .unavailable
        }
    }

    static func initialState(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution
    ) -> GuestImageReadinessGateState {
        initialState(for: target, resolution: resolution, registry: .shared)
    }

    static func bootstrapBaseURL(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry
    ) -> URL? {
        let server = registry.server(id: target.serverID)
        if let endpoint = server?.bootstrapEndpoint {
            return endpoint
        }

        let rawHost: String?
        switch resolution {
        case .server(let context):
            rawHost = server?.lastHost ?? context.host
        case .householdEndpoint(_, let endpoint):
            return endpoint
        case .unavailable:
            rawHost = server?.lastHost ?? server?.hostname
        }
        guard let rawHost, !rawHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return bootstrapURL(fromHost: rawHost)
    }

    static func bootstrapBaseURL(
        for target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution
    ) -> URL? {
        bootstrapBaseURL(for: target, resolution: resolution, registry: .shared)
    }

    private static func bootstrapURL(fromHost rawHost: String) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = scheme == "https" ? "https" : "http"
            components?.path = ""
            components?.query = nil
            components?.fragment = nil
            if components?.port == nil {
                components?.port = 8091
            }
            return components?.url
        }

        var host = trimmed
        var port: Int? = nil
        if !trimmed.hasPrefix("["),
           let colon = trimmed.lastIndex(of: ":"),
           trimmed[..<colon].contains(":") == false {
            let suffix = trimmed[trimmed.index(after: colon)...]
            if let parsed = Int(suffix) {
                host = String(trimmed[..<colon])
                port = parsed
            }
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        components.port = port ?? 8091
        return components.url
    }
}

@MainActor
final class GuestImageReadinessObserver: ObservableObject {
    @Published private(set) var state: GuestImageReadinessGateState

    private let client: GuestImageReadinessClient
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(
        initialState: GuestImageReadinessGateState,
        client: GuestImageReadinessClient,
        intervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.state = initialState
        self.client = client
        self.intervalNanoseconds = intervalNanoseconds
    }

    convenience init(
        initialState: GuestImageReadinessGateState,
        intervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.init(
            initialState: initialState,
            client: .shared,
            intervalNanoseconds: intervalNanoseconds
        )
    }

    func start(
        target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry
    ) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let next = await client.state(for: target, resolution: resolution, registry: registry)
                if Task.isCancelled { return }
                state = next
                if next.allowsInstall { return }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func start(
        target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution
    ) {
        start(target: target, resolution: resolution, registry: .shared)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
final class GuestImageReadinessMapObserver: ObservableObject {
    @Published private(set) var states: [String: GuestImageReadinessGateState] = [:]

    private let client: GuestImageReadinessClient
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(
        client: GuestImageReadinessClient,
        intervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.client = client
        self.intervalNanoseconds = intervalNanoseconds
    }

    convenience init(intervalNanoseconds: UInt64 = 5_000_000_000) {
        self.init(client: .shared, intervalNanoseconds: intervalNanoseconds)
    }

    func state(for server: Server) -> GuestImageReadinessGateState {
        states[server.id] ?? (server.kind == .linux ? .allowed(.notApplicable) : .checking)
    }

    func start(servers: [Server], registry: ServerRegistry) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var nextStates = states
                for server in servers {
                    let target = ClawInstallTarget(serverID: server.id)
                    let resolution = ClawInstallTargetResolver.resolve(target, registry: registry)
                    nextStates[server.id] = await client.state(
                        for: target,
                        resolution: resolution,
                        registry: registry
                    )
                }
                if Task.isCancelled { return }
                states = nextStates
                if !nextStates.values.contains(where: \.needsPolling) { return }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func start(servers: [Server]) {
        start(servers: servers, registry: .shared)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
