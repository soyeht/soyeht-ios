import ActivityKit
import Foundation

struct ClawDeployAttributes: ActivityAttributes {
    let clawName: String
    let clawType: String
    let cpuCores: Int
    let ramMB: Int
    let diskGB: Int
    let startDate: Date
    /// Instance ID so the Live Activity tap handler can deep-link into the
    /// specific instance once it becomes ready. Added in 2026-04-12 as part
    /// of the deploy UX improvements (Gap #6).
    let instanceId: String

    struct ContentState: Codable, Hashable {
        let status: String
        let message: String?
        let phase: String?
    }
}

/// Derived from ContentState for UI switching. Shared by main app and widget.
enum DeployPhase {
    case queuing, pulling, starting, ready, failed

    init(status: String, phase: String?) {
        if status == "active" { self = .ready; return }
        if status == "failed" { self = .failed; return }
        switch phase {
        case "pulling":  self = .pulling
        case "starting": self = .starting
        default:         self = .queuing
        }
    }
}
