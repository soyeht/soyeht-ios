import Foundation

// MARK: - Background Deploy Monitor
// Lives independently of any view. Polls provisioning status,
// updates the Live Activity, and sends a local notification on completion.

final class ClawDeployMonitor: ObservableObject {
    static let shared = ClawDeployMonitor()

    struct ActiveDeploy: Identifiable {
        let id: String          // instance ID
        let clawName: String
        let clawType: String
        var status: String
        var message: String?
        var phase: String?
    }

    @Published var activeDeploys: [ActiveDeploy] = []

    private let apiClient: SoyehtAPIClient
    private var tasks: [String: Task<Void, Never>] = [:]

    init(apiClient: SoyehtAPIClient = .shared) {
        self.apiClient = apiClient
    }

    /// Start monitoring a newly created instance. Call once after createInstance succeeds.
    /// The `context` routes status polling to whichever server hosts the new
    /// instance, independent of `SessionStore.activeServerId` (which the user
    /// may flip during the minutes the deploy takes to complete).
    @MainActor
    func monitor(instanceId: String, clawName: String, clawType: String, cpuCores: Int, ramMB: Int, diskGB: Int, context: ServerContext) {
        let deploy = ActiveDeploy(id: instanceId, clawName: clawName, clawType: clawType, status: "provisioning", phase: "queuing")
        activeDeploys.append(deploy)

        let activityManager = ClawDeployActivityManager()
        activityManager.startActivity(instanceId: instanceId, clawName: clawName, clawType: clawType, cpuCores: cpuCores, ramMB: ramMB, diskGB: diskGB)

        let apiClient = self.apiClient
        tasks[instanceId] = Task { @MainActor [weak self] in
            for _ in 0..<60 { // Max ~3 minutes
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }

                do {
                    let status = try await apiClient.getInstanceStatus(id: instanceId, context: context)
                    self.updateDeploy(id: instanceId, status: status.status, message: status.provisioningMessage, phase: status.provisioningPhase)
                    activityManager.updateActivity(status: status.status, message: status.provisioningMessage, phase: status.provisioningPhase)

                    if status.status != "provisioning" {
                        let success = status.status == "active"
                        activityManager.endActivity(status: status.status, message: status.provisioningMessage)
                        ClawNotificationHelper.sendDeployComplete(clawName: clawName, success: success)
                        self.removeDeploy(id: instanceId)
                        return
                    }
                } catch {
                    // Continue polling on transient errors
                }
            }

            // Timeout
            guard let self else { return }
            activityManager.endActivity(status: "failed", message: "Provisioning timed out")
            ClawNotificationHelper.sendDeployComplete(clawName: clawName, success: false)
            self.removeDeploy(id: instanceId)
        }
    }

    private func updateDeploy(id: String, status: String, message: String?, phase: String?) {
        if let idx = activeDeploys.firstIndex(where: { $0.id == id }) {
            activeDeploys[idx].status = status
            activeDeploys[idx].message = message
            activeDeploys[idx].phase = phase
        }
    }

    private func removeDeploy(id: String) {
        activeDeploys.removeAll(where: { $0.id == id })
        tasks[id]?.cancel()
        tasks[id] = nil
    }
}
