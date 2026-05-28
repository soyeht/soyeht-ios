import Foundation
import Combine

// MARK: - Claw Setup (Deploy) ViewModel

private enum InitialResourceValues {
    static let cpuCores = 2
    static let ramMB = 2048
    static let diskGB = 10
    static let warning = "live limits unavailable - current values are unverified; server will validate on deploy"
}

public struct ClawDeployOption: Sendable {
    public let server: PairedServer
    public let target: CreateInstanceTarget?

    public init(server: PairedServer, target: CreateInstanceTarget?) {
        self.server = server
        self.target = target
    }
}

public final class ClawSetupViewModel: ObservableObject {
    public let claw: Claw

    // Configuration
    @Published public var selectedServerIndex: Int = 0 {
        didSet {
            ensureServerTypeIsAvailable()
        }
    }
    @Published public var serverType: String = "linux"
    @Published public var clawName: String = ""
    @Published public var cpuCores: Int = InitialResourceValues.cpuCores
    @Published public var ramMB: Int = InitialResourceValues.ramMB
    @Published public var diskGB: Int = InitialResourceValues.diskGB

    // Assignment
    @Published public var assignmentTarget: AssignmentTarget = .admin
    @Published public var users: [ClawUser] = []

    // Resource limits
    @Published public var resourceOptions: ResourceOptions?
    @Published public var hasLiveResourceLimits = false

    // Deploy state
    @Published public var isDeploying = false
    @Published public var deploySucceeded = false
    @Published public var errorMessage: String?
    @Published public var resourceOptionsWarning: String?

    // Loading
    @Published public var isLoadingOptions = false

    private let apiClient: SoyehtAPIClient
    private let store: SessionStore
    private let deployMonitor: ClawDeployMonitor
    private let injectedDeployOptions: [ClawDeployOption]?

    /// Legacy init — preserved for macOS callers and existing tests.
    /// Reads `store.pairedServers` lazily via the `servers` computed.
    public init(
        claw: Claw,
        initialServerId: String? = nil,
        apiClient: SoyehtAPIClient = .shared,
        store: SessionStore = .shared,
        deployMonitor: ClawDeployMonitor = .shared
    ) {
        self.claw = claw
        self.apiClient = apiClient
        self.store = store
        self.deployMonitor = deployMonitor
        self.injectedDeployOptions = nil
        self.clawName = "\(claw.name)-workspace"
        if let initialServerId,
           let index = store.pairedServers.firstIndex(where: { $0.id == initialServerId }) {
            self.selectedServerIndex = index
        }
        setDefaultServerTypeFromSelectedServer()
    }

    /// PR-3 init — accepts an explicit list of `PairedServer` to show in
    /// the picker. iOS constructs this list from `ServerRegistry` filtered
    /// by `SessionStore.context(for:) != nil`, so the picker shows only
    /// servers that can actually receive a deploy (Macs paired via the
    /// household pair-machine flow without a per-Mac token are absent).
    ///
    /// The model itself is platform-agnostic: any caller that wants to
    /// override the default `store.pairedServers` list uses this init.
    /// Empty `servers` is valid and renders the "no deployable servers"
    /// placeholder.
    public init(
        claw: Claw,
        servers: [PairedServer],
        initialServerId: String? = nil,
        apiClient: SoyehtAPIClient = .shared,
        store: SessionStore = .shared,
        deployMonitor: ClawDeployMonitor = .shared
    ) {
        self.claw = claw
        self.apiClient = apiClient
        self.store = store
        self.deployMonitor = deployMonitor
        self.injectedDeployOptions = servers.map { server in
            let target = store.context(for: server.id).map(CreateInstanceTarget.server)
            return ClawDeployOption(server: server, target: target)
        }
        self.clawName = "\(claw.name)-workspace"
        if let initialServerId,
           let index = servers.firstIndex(where: { $0.id == initialServerId }) {
            self.selectedServerIndex = index
        }
        setDefaultServerTypeFromSelectedServer()
    }

    /// Explicit deploy-target init. Used by iOS when the selected Mac
    /// routes through a PoP-signed household endpoint instead of a legacy
    /// `ServerContext`.
    public init(
        claw: Claw,
        deployOptions: [ClawDeployOption],
        initialServerId: String? = nil,
        apiClient: SoyehtAPIClient = .shared,
        store: SessionStore = .shared,
        deployMonitor: ClawDeployMonitor = .shared
    ) {
        self.claw = claw
        self.apiClient = apiClient
        self.store = store
        self.deployMonitor = deployMonitor
        self.injectedDeployOptions = deployOptions
        self.clawName = "\(claw.name)-workspace"
        if let initialServerId,
           let index = deployOptions.firstIndex(where: { $0.server.id == initialServerId }) {
            self.selectedServerIndex = index
        }
        setDefaultServerTypeFromSelectedServer()
    }

    // MARK: - Computed

    public var servers: [PairedServer] {
        deployOptions.map(\.server)
    }

    public var selectedServer: PairedServer? {
        guard selectedServerIndex >= 0, selectedServerIndex < servers.count else { return nil }
        return servers[selectedServerIndex]
    }

    private var deployOptions: [ClawDeployOption] {
        injectedDeployOptions ?? store.pairedServers.compactMap { server in
            let target = store.context(for: server.id).map(CreateInstanceTarget.server)
            return ClawDeployOption(server: server, target: target)
        }
    }

    private var selectedDeployOption: ClawDeployOption? {
        let options = deployOptions
        guard selectedServerIndex >= 0, selectedServerIndex < options.count else { return nil }
        return options[selectedServerIndex]
    }

    public var nameValidationError: String? {
        let trimmed = clawName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 64 { return "name must be 64 characters or fewer" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "only letters, numbers, hyphens, and spaces allowed"
        }
        return nil
    }

    public var canDeploy: Bool {
        let trimmed = clawName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && nameValidationError == nil
            && selectedServer != nil
            && availableServerTypes.contains(serverType)
            && !isDeploying
    }

    public var availableServerTypes: [String] {
        switch selectedServer?.normalizedPlatform {
        case "linux":
            return ["linux"]
        case "macos":
            return ["linux", "macos"]
        default:
            return ["linux", "macos"]
        }
    }

    public var isDiskManagedByServer: Bool {
        if let disabled = resourceOptions?.diskGb.disabled {
            return disabled
        }
        return serverType == "macos"
    }

    public var showsDiskControl: Bool {
        !isDiskManagedByServer
    }

    public var canDecrementCPU: Bool {
        if hasLiveResourceLimits, let min = resourceOptions?.cpuCores.min {
            return cpuCores > min
        }
        return cpuCores > 1
    }

    public var canIncrementCPU: Bool {
        guard hasLiveResourceLimits, let max = resourceOptions?.cpuCores.max else { return true }
        return cpuCores < max
    }

    public var canDecrementRAM: Bool {
        let step = ramDecrementStep
        if hasLiveResourceLimits, let min = resourceOptions?.ramMb.min {
            return ramMB - step >= min
        }
        return ramMB - step > 0
    }

    public var canIncrementRAM: Bool {
        let step = ramIncrementStep
        guard hasLiveResourceLimits, let max = resourceOptions?.ramMb.max else { return true }
        return ramMB + step <= max
    }

    public var canDecrementDisk: Bool {
        guard showsDiskControl else { return false }
        if hasLiveResourceLimits, let min = resourceOptions?.diskGb.min {
            return diskGB - 5 >= min
        }
        return diskGB - 5 > 0
    }

    public var canIncrementDisk: Bool {
        guard showsDiskControl else { return false }
        guard hasLiveResourceLimits, let max = resourceOptions?.diskGb.max else { return true }
        return diskGB + 5 <= max
    }

    public func selectServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        selectedServerIndex = index
        ensureServerTypeIsAvailable()
    }

    public func selectServerType(_ type: String) {
        guard availableServerTypes.contains(type) else { return }
        serverType = type
    }

    private func setDefaultServerTypeFromSelectedServer() {
        guard let normalizedPlatform = selectedServer?.normalizedPlatform else { return }
        selectServerType(normalizedPlatform)
    }

    private func ensureServerTypeIsAvailable() {
        guard !availableServerTypes.contains(serverType) else { return }
        serverType = availableServerTypes.first ?? "linux"
    }

    // MARK: - Load Options

    @MainActor
    public func loadOptions() async {
        isLoadingOptions = true

        async let optionsTask: () = loadResourceOptions()
        async let usersTask: () = loadUsers()

        await optionsTask
        await usersTask

        isLoadingOptions = false
    }

    @MainActor
    private func loadResourceOptions() async {
        resourceOptionsWarning = nil
        guard let option = selectedDeployOption,
              case .server(let context) = option.target else {
            resourceOptions = nil
            hasLiveResourceLimits = false
            resourceOptionsWarning = InitialResourceValues.warning
            return
        }
        do {
            let options = try await apiClient.getResourceOptions(context: context)
            resourceOptions = options
            hasLiveResourceLimits = true
            cpuCores = options.cpuCores.default
            ramMB = options.ramMb.default
            diskGB = options.diskGb.default
        } catch {
            resourceOptions = nil
            hasLiveResourceLimits = false
            resourceOptionsWarning = InitialResourceValues.warning
        }
    }

    @MainActor
    private func loadUsers() async {
        guard let option = selectedDeployOption,
              case .server(let context) = option.target else { return }
        do {
            users = try await apiClient.getUsers(context: context)
        } catch {
            // Non-admin users get 403 — expected
        }
    }

    // MARK: - Deploy

    @MainActor
    public func deploy() async {
        guard canDeploy else { return }
        guard let option = selectedDeployOption else { return }
        let server = option.server
        guard let target = option.target else {
            errorMessage = "Missing session for \(server.name)"
            return
        }
        if case .server = target {
            // Validated by selectedDeployOption construction.
        } else {
            assignmentTarget = .admin
        }
        guard isDeployTargetAvailable(target) else {
            errorMessage = "Missing session for \(server.name)"
            return
        }

        isDeploying = true
        errorMessage = nil

        let ownerId: String? = {
            switch assignmentTarget {
            case .admin: return nil
            case .existingUser(let user): return user.id
            }
        }()

        let request = CreateInstanceRequest(
            name: clawName.trimmingCharacters(in: .whitespaces),
            clawType: claw.name,
            guestOs: serverType,
            cpuCores: cpuCores,
            ramMb: ramMB,
            diskGb: isDiskManagedByServer ? nil : diskGB,
            ownerId: ownerId
        )

        do {
            let response = try await apiClient.createInstance(request, target: target)

            deployMonitor.monitor(
                instanceId: response.id,
                clawName: clawName,
                clawType: claw.name,
                cpuCores: cpuCores,
                ramMB: ramMB,
                diskGB: diskGB,
                target: target
            )

            isDeploying = false
            deploySucceeded = true
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                errorMessage = body?.error ?? error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            isDeploying = false
        } catch {
            errorMessage = error.localizedDescription
            isDeploying = false
        }
    }

    private func isDeployTargetAvailable(_ target: CreateInstanceTarget) -> Bool {
        switch target {
        case .server:
            return true
        case .householdEndpoint:
            return true
        }
    }

    public func incrementCPU() {
        guard canIncrementCPU else { return }
        cpuCores += 1
    }

    public func decrementCPU() {
        guard canDecrementCPU else { return }
        cpuCores -= 1
    }

    public func incrementRAM() {
        guard canIncrementRAM else { return }
        ramMB += ramIncrementStep
    }

    public func decrementRAM() {
        guard canDecrementRAM else { return }
        ramMB -= ramDecrementStep
    }

    public func incrementDisk() {
        guard canIncrementDisk else { return }
        diskGB += 5
    }

    public func decrementDisk() {
        guard canDecrementDisk else { return }
        diskGB -= 5
    }

    private var ramIncrementStep: Int {
        ramMB >= 4096 ? 2048 : 1024
    }

    private var ramDecrementStep: Int {
        ramMB > 4096 ? 2048 : 1024
    }
}
