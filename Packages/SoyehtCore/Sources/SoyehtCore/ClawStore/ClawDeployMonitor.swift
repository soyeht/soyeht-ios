import Foundation
import Combine

// MARK: - Background Deploy Monitor
//
// Lives independently of any view. Polls provisioning status, drives an
// abstract activity manager (iOS: ActivityKit / macOS: no-op today, status
// item later), and dispatches a local notification on completion. The monitor
// is platform-free; the activity side-effect is injected.

@MainActor
public final class ClawDeployMonitor: ObservableObject {
    public static let shared = ClawDeployMonitor()

    public typealias StatusFetcher = (_ id: String, _ target: CreateInstanceTarget) async throws -> InstanceStatusResponse
    public typealias Sleeper = (_ nanoseconds: UInt64) async -> Void
    public typealias DeployCompleteNotifier = (_ clawName: String, _ success: Bool) -> Void
    public typealias DeployStillPreparingNotifier = (_ clawName: String) -> Void

    public static let checkLaterPhase = "check_later"
    public static let stillPreparingMessage = "Still preparing. Check later."

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
    public var activityManagerProvider: () -> ClawDeployActivityManaging = {
        NoOpClawDeployActivityManager()
    }

    private let pollAttempts: Int
    private let pollIntervalNanoseconds: UInt64
    private let sleeper: Sleeper
    private let fetchStatus: StatusFetcher
    private let notifyDeployComplete: DeployCompleteNotifier
    private let notifyDeployStillPreparing: DeployStillPreparingNotifier
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        apiClient: SoyehtAPIClient = .shared,
        pollAttempts: Int = 60,
        pollIntervalNanoseconds: UInt64 = 3_000_000_000,
        sleeper: @escaping Sleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        statusFetcher: StatusFetcher? = nil,
        notifyDeployComplete: @escaping DeployCompleteNotifier = { clawName, success in
            ClawNotificationHelper.sendDeployComplete(clawName: clawName, success: success)
        },
        notifyDeployStillPreparing: @escaping DeployStillPreparingNotifier = { clawName in
            ClawNotificationHelper.sendDeployStillPreparing(clawName: clawName)
        }
    ) {
        self.pollAttempts = max(0, pollAttempts)
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.sleeper = sleeper
        self.fetchStatus = statusFetcher ?? { id, target in
            try await apiClient.getInstanceStatus(id: id, target: target)
        }
        self.notifyDeployComplete = notifyDeployComplete
        self.notifyDeployStillPreparing = notifyDeployStillPreparing
    }

    /// Start monitoring a newly created instance. Call once after
    /// `createInstance` succeeds. The `context` routes status polling to the
    /// server that owns the new instance, independent of
    /// `SessionStore.activeServerId` (which the user may flip during the
    /// minutes the deploy takes to complete).
    public func monitor(
        instanceId: String,
        clawName: String,
        clawType: String,
        cpuCores: Int,
        ramMB: Int,
        diskGB: Int,
        context: ServerContext
    ) {
        monitor(
            instanceId: instanceId,
            clawName: clawName,
            clawType: clawType,
            cpuCores: cpuCores,
            ramMB: ramMB,
            diskGB: diskGB,
            target: .server(context)
        )
    }

    /// Start monitoring a newly created instance on either a legacy
    /// per-server session or a selected Mac household endpoint.
    public func monitor(
        instanceId: String,
        clawName: String,
        clawType: String,
        cpuCores: Int,
        ramMB: Int,
        diskGB: Int,
        target: CreateInstanceTarget
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

        let pollAttempts = self.pollAttempts
        let pollIntervalNanoseconds = self.pollIntervalNanoseconds
        let sleeper = self.sleeper
        let fetchStatus = self.fetchStatus
        let notifyDeployComplete = self.notifyDeployComplete
        let notifyDeployStillPreparing = self.notifyDeployStillPreparing
        tasks[instanceId] = Task { @MainActor [weak self] in
            for _ in 0..<pollAttempts {
                await sleeper(pollIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }

                do {
                    let status = try await fetchStatus(instanceId, target)
                    self.updateDeploy(
                        id: instanceId,
                        status: status.status.rawValue,
                        message: status.provisioningMessage,
                        phase: status.provisioningPhase
                    )
                    activityManager.updateActivity(
                        status: status.status.rawValue,
                        message: status.provisioningMessage,
                        phase: status.provisioningPhase
                    )

                    if status.status != .provisioning {
                        let success = status.status == .active
                        activityManager.endActivity(status: status.status.rawValue, message: status.provisioningMessage, phase: nil)
                        notifyDeployComplete(clawName, success)
                        self.removeDeploy(id: instanceId)
                        return
                    }
                } catch {
                    // Continue polling on transient errors
                }
            }

            // Timeout
            guard let self else { return }
            activityManager.endActivity(
                status: InstanceStatus.provisioning.rawValue,
                message: Self.stillPreparingMessage,
                phase: Self.checkLaterPhase
            )
            notifyDeployStillPreparing(clawName)
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
