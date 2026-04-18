import Foundation
import SoyehtCore

/// iOS-side model of a pane exposed by a paired Mac via presence.
/// Decoded from the `panes_snapshot` / `panes_delta` JSON.
struct PaneEntry: Identifiable, Equatable, Hashable, Codable {
    let id: String
    var title: String
    var agent: String
    var status: String
    var createdAt: Date?

    /// Localised SF Symbol name to render in the row alongside the title.
    var iconName: String {
        switch agent {
        case PaneWireAgent.claude: return "sparkles"
        case PaneWireAgent.codex:  return "curlybraces"
        case PaneWireAgent.hermes: return "bolt"
        case PaneWireAgent.shell:  return "terminal"
        default:                    return "rectangle.split.2x1"
        }
    }

    static func from(json: [String: Any]) -> PaneEntry? {
        guard let id = json["id"] as? String else { return nil }
        let title = (json["title"] as? String) ?? id
        let agent = (json["agent"] as? String) ?? PaneWireAgent.shell
        let status = (json["status"] as? String) ?? PaneWireStatus.active
        var createdAt: Date?
        if let iso = json["created_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            createdAt = f.date(from: iso)
        }
        return PaneEntry(
            id: id,
            title: title,
            agent: agent,
            status: status,
            createdAt: createdAt
        )
    }
}
