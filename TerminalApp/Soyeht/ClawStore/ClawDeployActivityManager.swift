import ActivityKit
import Foundation

final class ClawDeployActivityManager {
    private var activity: Activity<ClawDeployAttributes>?

    func startActivity(clawName: String, clawType: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ClawDeployAttributes(clawName: clawName, clawType: clawType)
        let state = ClawDeployAttributes.ContentState(status: "provisioning", message: nil)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: Date().addingTimeInterval(180))
        )
    }

    func updateActivity(status: String, message: String?) {
        let state = ClawDeployAttributes.ContentState(status: status, message: message)
        Task {
            await activity?.update(.init(state: state, staleDate: Date().addingTimeInterval(180)))
        }
    }

    func endActivity(status: String, message: String?) {
        let state = ClawDeployAttributes.ContentState(status: status, message: message)
        Task {
            await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 10))
            activity = nil
        }
    }
}
