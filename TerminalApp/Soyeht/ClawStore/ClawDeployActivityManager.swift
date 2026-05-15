import ActivityKit
import Foundation
import SoyehtCore

/// iOS adapter that wraps the shared `ClawDeployActivityManaging` contract
/// (SoyehtCore) with ActivityKit. The monitor in SoyehtCore calls through
/// this object for every deploy it tracks; macOS substitutes the no-op
/// manager provided by SoyehtCore.
final class ClawDeployActivityManager: ClawDeployActivityManaging, @unchecked Sendable {
    private var activity: Activity<ClawDeployAttributes>?

    init() {}

    func startActivity(instanceId: String, clawName: String, clawType: String, cpuCores: Int, ramMB: Int, diskGB: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ClawDeployAttributes(
            clawName: clawName,
            clawType: clawType,
            cpuCores: cpuCores,
            ramMB: ramMB,
            diskGB: diskGB,
            startDate: Date(),
            instanceId: instanceId
        )
        let state = ClawDeployAttributes.ContentState(status: "provisioning", message: nil, phase: "queuing")
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: Date().addingTimeInterval(180))
        )
    }

    func updateActivity(status: String, message: String?, phase: String?) {
        let state = ClawDeployAttributes.ContentState(status: status, message: message, phase: phase)
        Task {
            await activity?.update(.init(state: state, staleDate: Date().addingTimeInterval(180)))
        }
    }

    func endActivity(status: String, message: String?) {
        let finalPhase: String? = status == "active" ? "ready" : nil
        let state = ClawDeployAttributes.ContentState(status: status, message: message, phase: finalPhase)
        Task {
            await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 10))
            activity = nil
        }
    }
}
