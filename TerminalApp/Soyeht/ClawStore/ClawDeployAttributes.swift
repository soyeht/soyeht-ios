import ActivityKit
import Foundation

struct ClawDeployAttributes: ActivityAttributes {
    let clawName: String
    let clawType: String

    struct ContentState: Codable, Hashable {
        let status: String
        let message: String?
    }
}
