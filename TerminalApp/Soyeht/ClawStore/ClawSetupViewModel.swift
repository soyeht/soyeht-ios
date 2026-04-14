import Foundation
import Combine

// MARK: - Claw Setup (Deploy) ViewModel

private enum InitialResourceValues {
    static let cpuCores = 2
    static let ramMB = 2048
    static let diskGB = 10
    static let warning = "live limits unavailable - current values are unverified; server will validate on deploy"
}

final class ClawSetupViewModel: ObservableObject {
    let claw: Claw

    // Configuration
    @Published var selectedServerIndex: Int = 0
    @Published var serverType: String = "linux"
    @Published var clawName: String = ""
    @Published var cpuCores: Int = InitialResourceValues.cpuCores
    @Published var ramMB: Int = InitialResourceValues.ramMB
    @Published var diskGB: Int = InitialResourceValues.diskGB

    // Assignment
    @Published var assignmentTarget: AssignmentTarget = .admin
    @Published var users: [ClawUser] = []

    // Resource limits
    @Published var resourceOptions: ResourceOptions?
    @Published var hasLiveResourceLimits = false

    // Deploy state
    @Published var isDeploying = false
    @Published var deploySucceeded = false
    @Published var errorMessage: String?
    @Published var resourceOptionsWarning: String?

    // Loading
    @Published var isLoadingOptions = false

    private let apiClient: SoyehtAPIClient
    private let store: SessionStore
    private let deployMonitor: ClawDeployMonitor

    init(
        claw: Claw,
        apiClient: SoyehtAPIClient = .shared,
        store: SessionStore = .shared,
        deployMonitor: ClawDeployMonitor = .shared
    ) {
        self.claw = claw
        self.apiClient = apiClient
        self.store = store
        self.deployMonitor = deployMonitor
        self.clawName = "\(claw.name)-workspace"
    }

    // MARK: - Computed

    var servers: [PairedServer] {
        store.pairedServers
    }

    var selectedServer: PairedServer? {
        guard selectedServerIndex >= 0, selectedServerIndex < servers.count else { return nil }
        return servers[selectedServerIndex]
    }

    var nameValidationError: String? {
        let trimmed = clawName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 64 { return "name must be 64 characters or fewer" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "only letters, numbers, hyphens, and spaces allowed"
        }
        return nil
    }

    var canDeploy: Bool {
        let trimmed = clawName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && nameValidationError == nil
            && selectedServer != nil
            && !isDeploying
    }

    var isDiskManagedByServer: Bool {
        if let disabled = resourceOptions?.diskGb.disabled {
            return disabled
        }
        return serverType == "macos"
    }

    var showsDiskControl: Bool {
        !isDiskManagedByServer
    }

    var canDecrementCPU: Bool {
        if hasLiveResourceLimits, let min = resourceOptions?.cpuCores.min {
            return cpuCores > min
        }
        return cpuCores > 1
    }

    var canIncrementCPU: Bool {
        guard hasLiveResourceLimits, let max = resourceOptions?.cpuCores.max else { return true }
        return cpuCores < max
    }

    var canDecrementRAM: Bool {
        let step = ramDecrementStep
        if hasLiveResourceLimits, let min = resourceOptions?.ramMb.min {
            return ramMB - step >= min
        }
        return ramMB - step > 0
    }

    var canIncrementRAM: Bool {
        let step = ramIncrementStep
        guard hasLiveResourceLimits, let max = resourceOptions?.ramMb.max else { return true }
        return ramMB + step <= max
    }

    var canDecrementDisk: Bool {
        guard showsDiskControl else { return false }
        if hasLiveResourceLimits, let min = resourceOptions?.diskGb.min {
            return diskGB - 5 >= min
        }
        return diskGB - 5 > 0
    }

    var canIncrementDisk: Bool {
        guard showsDiskControl else { return false }
        guard hasLiveResourceLimits, let max = resourceOptions?.diskGb.max else { return true }
        return diskGB + 5 <= max
    }

    // MARK: - Load Options

    @MainActor
    func loadOptions() async {
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
        do {
            let options = try await apiClient.getResourceOptions()
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
        do {
            users = try await apiClient.getUsers()
        } catch {
            // Non-admin users get 403, which is expected
        }
    }

    // MARK: - Deploy

    @MainActor
    func deploy() async {
        guard canDeploy else { return }
        guard let server = selectedServer else { return }

        isDeploying = true
        errorMessage = nil

        // Ensure we're targeting the right server
        store.setActiveServer(id: server.id)

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
            let response = try await apiClient.createInstance(request)

            // Hand off to background monitor — polling, Live Activity, and
            // notifications all happen independently of this view.
            deployMonitor.monitor(
                instanceId: response.id,
                clawName: clawName,
                clawType: claw.name,
                cpuCores: cpuCores,
                ramMB: ramMB,
                diskGB: diskGB
            )

            isDeploying = false
            deploySucceeded = true
        } catch let error as SoyehtAPIClient.APIError {
            // Preserve access to the structured error body (code + reasons)
            // for future UX enrichment. Today we surface body?.error as the
            // visible string; body?.reasons is available via error.httpError
            // body to a future enhancement without re-touching the transport.
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

    func incrementCPU() {
        guard canIncrementCPU else { return }
        cpuCores += 1
    }

    func decrementCPU() {
        guard canDecrementCPU else { return }
        cpuCores -= 1
    }

    func incrementRAM() {
        guard canIncrementRAM else { return }
        ramMB += ramIncrementStep
    }

    func decrementRAM() {
        guard canDecrementRAM else { return }
        ramMB -= ramDecrementStep
    }

    func incrementDisk() {
        guard canIncrementDisk else { return }
        diskGB += 5
    }

    func decrementDisk() {
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
