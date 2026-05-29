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

    func clearCache(for target: ClawInstallTarget) {
        cache.removeValue(forKey: target.serverID)
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

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = scheme
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
final class GuestImagePreparationClient {
    typealias PrepareRequest = (URL, Bool) async throws -> GuestImagePrepareResponse

    static let shared = GuestImagePreparationClient()

    private let prepareRequest: PrepareRequest

    init(
        apiClient: SoyehtAPIClient = .shared,
        prepareRequest: PrepareRequest? = nil
    ) {
        if let prepareRequest {
            self.prepareRequest = prepareRequest
            return
        }
        self.prepareRequest = { endpoint, force in
            let body: Data?
            var headers = ["Accept": "application/json"]
            if force {
                body = try apiClient.encoder.encode(GuestImagePrepareBody(force: true))
                headers["Content-Type"] = "application/json"
            } else {
                body = nil
            }
            let (data, _) = try await apiClient.householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/guest-image/prepare",
                method: "POST",
                body: body,
                requiredOperation: "claws.create",
                additionalHeaders: headers
            )
            return try apiClient.decoder.decode(GuestImagePrepareResponse.self, from: data)
        }
    }

    func prepare(endpoint: URL, force: Bool = false) async throws -> GuestImageReadinessGateState {
        try await prepareRequest(endpoint, force).gateState
    }
}

private struct GuestImagePrepareBody: Encodable {
    let force: Bool
}

struct GuestImagePrepareResponse: Decodable, Equatable, Sendable {
    let v: Int
    let status: String
    let guestImagePhase: String?
    let guestImageStatus: String?
    let guestImageError: String?
    /// Machine-readable failure reason (theyos PR #89). Fail-soft: unknown/future
    /// codes decode to `.unknown`; absent on older engines. Decoded via the API
    /// client's `.convertFromSnakeCase` strategy.
    let guestImageFailureCode: GuestImageFailureCode?

    var gateState: GuestImageReadinessGateState {
        switch status {
        case "done":
            return .allowed(.ready)
        case "starting":
            return .blocked(.inProgress(phase: guestImagePhase ?? "starting"))
        case "in_progress", "pending":
            return .blocked(.inProgress(phase: guestImagePhase ?? guestImageStatus ?? status))
        case "failed":
            return .blocked(.failed(error: guestImageError, code: guestImageFailureCode))
        case "not_supported":
            return .allowed(.notApplicable)
        default:
            switch guestImageStatus {
            case "done":
                return .allowed(.ready)
            case "failed":
                return .blocked(.failed(error: guestImageError, code: guestImageFailureCode))
            case "in_progress", "pending":
                return .blocked(.inProgress(phase: guestImagePhase ?? guestImageStatus ?? status))
            default:
                return .blocked(.inProgress(phase: guestImagePhase ?? status))
            }
        }
    }
}

@MainActor
final class GuestImageReadinessObserver: ObservableObject {
    @Published private(set) var state: GuestImageReadinessGateState
    @Published private(set) var isPreparing = false
    @Published private(set) var prepareError: String?

    private let client: GuestImageReadinessClient
    private let preparationClient: GuestImagePreparationClient
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(
        initialState: GuestImageReadinessGateState,
        client: GuestImageReadinessClient,
        preparationClient: GuestImagePreparationClient = .shared,
        intervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.state = initialState
        self.client = client
        self.preparationClient = preparationClient
        self.intervalNanoseconds = intervalNanoseconds
    }

    convenience init(
        initialState: GuestImageReadinessGateState,
        intervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.init(
            initialState: initialState,
            client: .shared,
            preparationClient: .shared,
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

    func prepare(
        target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry,
        force: Bool = false
    ) async {
        guard !isPreparing else { return }
        guard let endpoint = GuestImageReadinessClient.bootstrapBaseURL(
            for: target,
            resolution: resolution,
            registry: registry
        ) else {
            prepareError = String(
                localized: "clawDetail.guestImage.prepare.error.noEndpoint",
                defaultValue: "This Mac is not reachable yet. Check that Soyeht is running on the Mac.",
                comment: "Error shown when iPhone cannot compute a Mac endpoint for remote guest-image preparation."
            )
            state = .unavailable
            return
        }

        task?.cancel()
        isPreparing = true
        prepareError = nil
        do {
            let next = try await preparationClient.prepare(endpoint: endpoint, force: force)
            client.clearCache(for: target)
            state = next
            if next.needsPolling {
                start(target: target, resolution: resolution, registry: registry)
            }
        } catch {
            prepareError = Self.userFacingPrepareError(error)
        }
        isPreparing = false
    }

    func prepare(
        target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        force: Bool = false
    ) async {
        await prepare(target: target, resolution: resolution, registry: .shared, force: force)
    }

    /// Re-fetch the Mac's guest-image readiness from `/bootstrap/status` WITHOUT
    /// issuing a preparation request. This backs the "Check Again" action for
    /// `host_vm_limit_reached` (`.restartMacRequired`): after the user restarts the
    /// Mac, a status refresh — not a prepare retry into a still-blocked host —
    /// is what should update the UI.
    func refreshStatus(
        target: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution,
        registry: ServerRegistry = .shared
    ) async {
        guard !isPreparing else { return }
        prepareError = nil
        client.clearCache(for: target)
        let next = await client.state(for: target, resolution: resolution, registry: registry)
        state = next
        if next.needsPolling {
            start(target: target, resolution: resolution, registry: registry)
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

    private static func userFacingPrepareError(_ error: Error) -> String {
        if let apiError = error as? SoyehtAPIClient.APIError {
            switch apiError {
            case .httpError(503, _):
                return String(
                    localized: "clawDetail.guestImage.prepare.error.helperMissing",
                    defaultValue: "This Mac cannot start preparation yet. Update Soyeht on the Mac, then try again.",
                    comment: "Error shown when a Mac lacks the guest-image helper needed for remote preparation."
                )
            case .httpError(409, _):
                return String(
                    localized: "clawDetail.guestImage.prepare.error.forceRequired",
                    defaultValue: "The last preparation failed. Use Try Again to restart it.",
                    comment: "Error shown when the Mac requires a force retry for guest-image preparation."
                )
            case .httpError(501, _):
                return String(
                    localized: "clawDetail.guestImage.prepare.error.notSupported",
                    defaultValue: "This server does not need Mac preparation.",
                    comment: "Error shown when guest-image preparation is requested for a non-Mac server."
                )
            default:
                break
            }
        }
        // Last resort (transport/unexpected): a friendly generic line — never the
        // raw daemon/VZErrorDomain string as a primary message. Reason-coded
        // recovery copy comes from the readiness `.failed(code:)` state (the SSoT).
        return String(
            localized: "clawDetail.guestImage.prepare.error.generic",
            defaultValue: "Couldn't start preparation on this Mac. Check the Mac's connection and try again.",
            comment: "Generic fallback when a guest-image preparation request fails for an unclassified/transport reason."
        )
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

/// UI-layer copy for guest-image preparation failures. **Translation only** — it
/// turns a ``GuestImageFailureCode`` into localized title/body/instruction strings
/// and a ``GuestImageRecoveryAction`` into a button label. It does **not** decide
/// the recovery action; that comes exclusively from `code.recoveryAction` in
/// SoyehtCore (the domain). The View reads the action from the domain and asks this
/// helper only for the words.
enum GuestImageFailureCopy {
    /// Card title for a failure code. `nil` code (older engine that didn't send one)
    /// maps to the generic copy.
    static func title(for code: GuestImageFailureCode?) -> LocalizedStringResource {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.hostVmLimitReached.title",
                defaultValue: "This Mac needs a restart before preparing",
                comment: "Title when guest-image prep failed because macOS hit its active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.helperMissing.title",
                defaultValue: "Finish setup on the Mac",
                comment: "Title when guest-image prep needs a helper/setup step on the Mac."
            )
        case .insufficientDisk:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.insufficientDisk.title",
                defaultValue: "Not enough space on the Mac",
                comment: "Title when guest-image prep failed for lack of disk space."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.entitlementMissing.title",
                defaultValue: "Reinstall Soyeht on the Mac",
                comment: "Title when guest-image prep failed because the Mac install can't run VMs."
            )
        case .ipswDownloadFailed:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.ipswDownloadFailed.title",
                defaultValue: "Couldn't download the macOS image",
                comment: "Title when the macOS restore image download failed."
            )
        case .ipswIncompatible:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.ipswIncompatible.title",
                defaultValue: "This Mac isn't supported yet",
                comment: "Title when no compatible restore image exists for this Mac."
            )
        case .unknown:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.unknown.title",
                defaultValue: "Couldn't prepare this Mac",
                comment: "Generic title when guest-image prep failed for an unclassified reason."
            )
        }
    }

    /// Short explanatory body.
    static func body(for code: GuestImageFailureCode?) -> LocalizedStringResource {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.hostVmLimitReached.body",
                defaultValue: "macOS is still holding an earlier virtual machine. Restarting clears it.",
                comment: "Body explaining the macOS active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.helperMissing.body",
                defaultValue: "This Mac needs a quick setup step before it can prepare.",
                comment: "Body for the helper/setup-missing failure."
            )
        case .insufficientDisk:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.insufficientDisk.body",
                defaultValue: "Free up space on the Mac, then try again.",
                comment: "Body for the insufficient-disk failure."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.entitlementMissing.body",
                defaultValue: "This Mac's Soyeht install can't run virtual machines.",
                comment: "Body for the missing-entitlement failure."
            )
        case .ipswDownloadFailed:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.ipswDownloadFailed.body",
                defaultValue: "Check the Mac's connection and try again.",
                comment: "Body for the restore-image download failure."
            )
        case .ipswIncompatible:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.ipswIncompatible.body",
                defaultValue: "This Mac's macOS version isn't supported for preparation.",
                comment: "Body for the incompatible-restore-image failure."
            )
        case .unknown:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.unknown.body",
                defaultValue: "Something went wrong preparing this Mac.",
                comment: "Generic body when guest-image prep failed."
            )
        }
    }

    /// Optional secondary instruction line (what to do on the Mac). `nil` when the
    /// body already says everything.
    static func secondaryInstruction(for code: GuestImageFailureCode?) -> LocalizedStringResource? {
        switch code ?? .unknown {
        case .hostVmLimitReached:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.hostVmLimitReached.instruction",
                defaultValue: "Restart Soyeht on the Mac, or restart the Mac.",
                comment: "Instruction for clearing the macOS active-VM limit."
            )
        case .helperMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.helperMissing.instruction",
                defaultValue: "Open Soyeht on the Mac to finish setup.",
                comment: "Instruction for the helper/setup-missing failure."
            )
        case .entitlementMissing:
            return LocalizedStringResource(
                "clawStore.guestImage.failure.entitlementMissing.instruction",
                defaultValue: "Reinstall Soyeht on the Mac, then check again.",
                comment: "Instruction for the missing-entitlement failure."
            )
        case .insufficientDisk, .ipswDownloadFailed, .ipswIncompatible, .unknown:
            return nil
        }
    }

    /// Joins the optional raw engine `detail` and the transient `prepareError` into
    /// the single secondary string shown behind a "Details" disclosure. Returns nil
    /// when neither is present. Raw daemon/`VZErrorDomain` text must never be a
    /// primary line — only this secondary detail.
    static func combinedRawDetail(detail: String?, prepareError: String?) -> String? {
        let parts = [detail, prepareError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Button label for a recovery action. The **action** is decided by the domain
    /// (`code.recoveryAction`); this only supplies the words. Returns `nil` for
    /// `.none` (no button).
    static func primaryLabel(for action: GuestImageRecoveryAction) -> LocalizedStringResource? {
        switch action {
        case .retry, .freeSpaceThenRetry:
            return LocalizedStringResource(
                "clawStore.guestImage.action.tryAgain",
                defaultValue: "Try Again",
                comment: "Primary CTA that re-invokes guest-image preparation."
            )
        case .restartMacRequired, .openSoyehtOnMac, .reinstallSoyehtOnMac:
            return LocalizedStringResource(
                "clawStore.guestImage.action.checkAgain",
                defaultValue: "Check Again",
                comment: "Primary CTA that re-checks Mac status (no prepare) after the user acts on the Mac."
            )
        case .none:
            return nil
        }
    }
}
