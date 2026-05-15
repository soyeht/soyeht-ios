import Foundation
import Combine

// MARK: - Background Deploy Monitor
//
// Lives independently of any view. Polls provisioning status, drives an
// abstract activity manager (iOS: ActivityKit / macOS: no-op today, status
// item later), and dispatches a local notification on completion. The monitor
// is platform-free; the activity side-effect is injected.

public final class ClawDeployMonitor: ObservableObject {
    public static let shared = ClawDeployMonitor()

    public struct ActiveDeploy: Identifiable, Sendable {
        public let id: String          // instance ID
        public let clawName: String
        public let clawType: String
        public var status: String
        public var message: String?
        public var phase: String?

        public init(id: String, clawName: String, clawType: String, status: String, message: String? = nil, phase: String? = nil) {
            self.id = id
            self.clawName = clawName
            self.clawType = clawType
            self.status = status
            self.message = message
            self.phase = phase
        }
    }

    @Published public var activeDeploys: [ActiveDeploy] = []

    /// Replaceable at app start so iOS wires in ActivityKit and macOS keeps
    /// the no-op. Each call to `monitor(...)` pulls a fresh manager from this
    /// factory so per-deploy state doesn't leak across concurrent deploys.
    @MainActor
    public var activityManagerProvider: () -> ClawDeployActivityManaging = {
        NoOpClawDeployActivityManager()
    }

    private let apiClient: SoyehtAPIClient
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(apiClient: SoyehtAPIClient = .shared) {
        self.apiClient = apiClient
    }

    /// Start monitoring a newly created instance. Call once after
    /// `createInstance` succeeds. The `context` routes status polling to the
    /// server that owns the new instance, independent of
    /// `SessionStore.activeServerId` (which the user may flip during the
    /// minutes the deploy takes to complete).
    @MainActor
    public func monitor(
        instanceId: String,
        clawName: String,
        clawType: String,
        cpuCores: Int,
        ramMB: Int,
        diskGB: Int,
        context: ServerContext
    ) {
        let deploy = ActiveDeploy(
            id: instanceId,
            clawName: clawName,
            clawType: clawType,
            status: "provisioning",
            phase: "queuing"
        )
        activeDeploys.append(deploy)

        let activityManager = activityManagerProvider()
        activityManager.startActivity(
            instanceId: instanceId,
            clawName: clawName,
            clawType: clawType,
            cpuCores: cpuCores,
            ramMB: ramMB,
            diskGB: diskGB
        )

        let apiClient = self.apiClient
        tasks[instanceId] = Task { @MainActor [weak self] in
            for _ in 0..<60 { // ~3 minutes of polling (60 × 3s)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }

                do {
                    let status = try await apiClient.getInstanceStatus(id: instanceId, context: context)
                    self.updateDeploy(
                        id: instanceId,
                        status: status.status,
                        message: status.provisioningMessage,
                        phase: status.provisioningPhase
                    )
                    activityManager.updateActivity(
                        status: status.status,
                        message: status.provisioningMessage,
                        phase: status.provisioningPhase
                    )

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
