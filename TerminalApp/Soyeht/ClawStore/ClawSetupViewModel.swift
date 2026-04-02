import Foundation
import Combine

// MARK: - Claw Setup (Deploy) ViewModel

final class ClawSetupViewModel: ObservableObject {
    let claw: Claw

    // Configuration
    @Published var selectedServerIndex: Int = 0
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
    @Published var deployedInstanceId: String?
    @Published var provisioningStatus: String?
    @Published var provisioningMessage: String?
    @Published var provisioningError: String?
    @Published var errorMessage: String?

    // Loading
    @Published var isLoadingOptions = false

    private let apiClient: SoyehtAPIClient
    private let store: SessionStore

    init(claw: Claw, apiClient: SoyehtAPIClient = .shared, store: SessionStore = .shared) {
        self.claw = claw
        self.apiClient = apiClient
        self.store = store
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

    var canDeploy: Bool {
        !clawName.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedServer != nil
            && !isDeploying
    }

    var isProvisioning: Bool {
        deployedInstanceId != nil && provisioningStatus == "provisioning"
    }

    var isDeployComplete: Bool {
        provisioningStatus == "active"
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
            // Use defaults if API unavailable
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
            case .invite: return nil
            }
        }()

        let request = CreateInstanceRequest(
            name: clawName.trimmingCharacters(in: .whitespaces),
            claw_type: claw.name,
            cpu_cores: cpuCores,
            ram_mb: ramMB,
            disk_gb: diskGB,
            owner_id: ownerId
        )

        do {
            let response = try await apiClient.createInstance(request)
            deployedInstanceId = response.id
            provisioningStatus = response.status

            if response.status == "provisioning" {
                await pollProvisioningStatus(instanceId: response.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            isDeploying = false
        }
    }

    // MARK: - Provisioning Polling

    @MainActor
    private func pollProvisioningStatus(instanceId: String) async {
        for _ in 0..<40 { // Max ~2 minutes (40 * 3s)
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            do {
                let status = try await apiClient.getInstanceStatus(id: instanceId)
                provisioningStatus = status.status
                provisioningMessage = status.provisioning_message
                provisioningError = status.provisioning_error

                if status.status != "provisioning" {
                    isDeploying = false
                    return
                }
            } catch {
                // Continue polling on transient errors
            }
        }

        // Timeout
        provisioningError = "Provisioning timed out"
        isDeploying = false
    }
}
