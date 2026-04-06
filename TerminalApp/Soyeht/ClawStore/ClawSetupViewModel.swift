import Foundation
import Combine

// MARK: - Claw Setup (Deploy) ViewModel

final class ClawSetupViewModel: ObservableObject {
    let claw: Claw

    // Configuration
    @Published var selectedServerIndex: Int = 0
    @Published var serverType: String = "linux"
    @Published var clawName: String = ""
    @Published var cpuCores: Int = 2
    @Published var ramMB: Int = 2048
    @Published var diskGB: Int = 10

    // Assignment
    @Published var assignmentTarget: AssignmentTarget = .admin
    @Published var users: [ClawUser] = []

    // Resource limits
    @Published var resourceOptions: ResourceOptions?

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
        do {
            let options = try await apiClient.getResourceOptions()
            resourceOptions = options
            cpuCores = options.cpu_cores.default
            ramMB = options.ram_mb.default
            diskGB = options.disk_gb.default
        } catch {
            resourceOptionsWarning = "using default limits — server unavailable"
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
            claw_type: claw.name,
            guest_os: serverType,
            cpu_cores: cpuCores,
            ram_mb: ramMB,
            disk_gb: diskGB,
            owner_id: ownerId
        )

        do {
            let response = try await apiClient.createInstance(request)

            // Hand off to background monitor — polling, Live Activity, and
            // notifications all happen independently of this view.
            deployMonitor.monitor(
                instanceId: response.id,
                clawName: clawName,
                clawType: claw.name
            )

            isDeploying = false
            deploySucceeded = true
        } catch {
            errorMessage = error.localizedDescription
            isDeploying = false
        }
    }
}
