import Foundation
import Combine

// MARK: - Claw Setup (Deploy) ViewModel

private enum InitialResourceValues {
    static let cpuCores = 2
    static let ramMB = 2048
    static let diskGB = 10
    static let warning = "live limits unavailable - current values are unverified; server will validate on deploy"
}

public final class ClawSetupViewModel: ObservableObject {
    public let claw: Claw

    // Configuration
    @Published public var selectedServerIndex: Int = 0
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
        self.clawName = "\(claw.name)-workspace"
        if let initialServerId,
           let index = store.pairedServers.firstIndex(where: { $0.id == initialServerId }) {
            self.selectedServerIndex = index
        }
    }

    // MARK: - Computed

    public var servers: [PairedServer] {
        store.pairedServers
    }

    public var selectedServer: PairedServer? {
        guard selectedServerIndex >= 0, selectedServerIndex < servers.count else { return nil }
        return servers[selectedServerIndex]
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
            && !isDeploying
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
        guard let server = selectedServer,
              let context = store.context(for: server.id) else {
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
        guard let server = selectedServer,
              let context = store.context(for: server.id) else { return }
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
        guard let server = selectedServer else { return }
        guard let context = store.context(for: server.id) else {
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
            let response = try await apiClient.createInstance(request, context: context)

            deployMonitor.monitor(
                instanceId: response.id,
                clawName: clawName,
                clawType: claw.name,
                cpuCores: cpuCores,
                ramMB: ramMB,
                diskGB: diskGB,
                context: context
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
