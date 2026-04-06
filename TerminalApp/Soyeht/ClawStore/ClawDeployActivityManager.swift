import ActivityKit
import Foundation

final class ClawDeployActivityManager {
    private var activity: Activity<ClawDeployAttributes>?

    func startActivity(clawName: String, clawType: String, cpuCores: Int, ramMB: Int, diskGB: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ClawDeployAttributes(
            clawName: clawName,
            clawType: clawType,
            cpuCores: cpuCores,
            ramMB: ramMB,
            diskGB: diskGB,
            startDate: Date()
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
