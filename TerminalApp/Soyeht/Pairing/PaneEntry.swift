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
    var workspaceID: String? = nil
    var windowID: String? = nil
    var isFocused: Bool = false
    var isLive: Bool = true
    var isAttachable: Bool = true
    var orderIndex: Int? = nil
    var workingDirectory: String? = nil

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
        let isLive = (json["is_live"] as? Bool) ?? true
        let isAttachable = (json["is_attachable"] as? Bool) ?? isLive
        return PaneEntry(
            id: id,
            title: title,
            agent: agent,
            status: status,
            createdAt: createdAt,
            workspaceID: json["workspace_id"] as? String,
            windowID: json["window_id"] as? String,
            isFocused: (json["is_focused"] as? Bool) ?? false,
            isLive: isLive,
            isAttachable: isAttachable,
            orderIndex: json["order_index"] as? Int,
            workingDirectory: json["working_directory"] as? String
        )
    }
}

indirect enum PaneLayoutNode: Equatable, Hashable, Codable {
    case leaf(String)
    case split(axis: String, ratio: Double, children: [PaneLayoutNode])

    static func from(json: [String: Any]) -> PaneLayoutNode? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "leaf":
            guard let paneID = json["pane_id"] as? String else { return nil }
            return .leaf(paneID)
        case "split":
            let axis = (json["axis"] as? String) ?? "vertical"
            let ratio = (json["ratio"] as? Double)
                ?? (json["ratio"] as? NSNumber)?.doubleValue
                ?? 0.5
            let children = (json["children"] as? [[String: Any]])?
                .compactMap { PaneLayoutNode.from(json: $0) }
                ?? []
            guard !children.isEmpty else { return nil }
            return .split(axis: axis, ratio: ratio, children: children)
        default:
            return nil
        }
    }

    var leafIDs: [String] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let children):
            return children.flatMap(\.leafIDs)
        }
    }

    func flattenedLeaves(depth: Int = 0) -> [(id: String, depth: Int)] {
        switch self {
        case .leaf(let id):
            return [(id, depth)]
        case .split(_, _, let children):
            return children.flatMap { $0.flattenedLeaves(depth: depth + 1) }
        }
    }

    static func linear(_ ids: [String]) -> PaneLayoutNode? {
        guard let first = ids.first else { return nil }
        guard ids.count > 1 else { return .leaf(first) }
        let rest = linear(Array(ids.dropFirst())).map { [$0] } ?? []
        return .split(axis: "vertical", ratio: 1.0 / Double(ids.count), children: [.leaf(first)] + rest)
    }
}

struct WorkspaceEntry: Identifiable, Equatable, Hashable, Codable {
    let id: String
    var name: String
    var kind: String
    var branch: String?
    var activePaneID: String?
    var isActive: Bool
    var paneCount: Int
    var orderIndex: Int
    var layout: PaneLayoutNode?
    var panes: [PaneEntry]
    var activeWindowIDs: [String]

    static func from(json: [String: Any]) -> WorkspaceEntry? {
        guard let id = json["id"] as? String else { return nil }
        let panes = (json["panes"] as? [[String: Any]])?
            .compactMap { PaneEntry.from(json: $0) }
            ?? []
        let layout = (json["layout"] as? [String: Any]).flatMap(PaneLayoutNode.from(json:))
            ?? PaneLayoutNode.linear(panes.map(\.id))
        return WorkspaceEntry(
            id: id,
            name: (json["name"] as? String) ?? id,
            kind: (json["kind"] as? String) ?? "adhoc",
            branch: json["branch"] as? String,
            activePaneID: json["active_pane_id"] as? String,
            isActive: (json["is_active"] as? Bool) ?? false,
            paneCount: (json["pane_count"] as? Int) ?? panes.count,
            orderIndex: (json["order_index"] as? Int) ?? 0,
            layout: layout,
            panes: panes.sorted { ($0.orderIndex ?? 0, $0.title) < ($1.orderIndex ?? 0, $1.title) },
            activeWindowIDs: (json["active_window_ids"] as? [String]) ?? []
        )
    }

    var orderedPaneRows: [WorkspacePaneRow] {
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        var seen = Set<String>()
        var rows: [WorkspacePaneRow] = []
        for leaf in layout?.flattenedLeaves() ?? [] {
            guard let pane = byID[leaf.id] else { continue }
            seen.insert(pane.id)
            rows.append(WorkspacePaneRow(pane: pane, depth: leaf.depth))
        }
        for pane in panes where !seen.contains(pane.id) {
            rows.append(WorkspacePaneRow(pane: pane, depth: 0))
        }
        return rows
    }
}

struct WorkspacePaneRow: Identifiable, Equatable, Hashable {
    var id: String { pane.id }
    let pane: PaneEntry
    let depth: Int
}

struct MacWindowEntry: Identifiable, Equatable, Hashable, Codable {
    let id: String
    var title: String
    var activeWorkspaceID: String?
    var isKey: Bool
    var isMain: Bool
    var isVisible: Bool
    var isMiniaturized: Bool
    var workspaces: [WorkspaceEntry]

    static func from(json: [String: Any]) -> MacWindowEntry? {
        guard let id = json["id"] as? String else { return nil }
        return MacWindowEntry(
            id: id,
            title: (json["title"] as? String) ?? "Soyeht",
            activeWorkspaceID: json["active_workspace_id"] as? String,
            isKey: (json["is_key"] as? Bool) ?? false,
            isMain: (json["is_main"] as? Bool) ?? false,
            isVisible: (json["is_visible"] as? Bool) ?? true,
            isMiniaturized: (json["is_miniaturized"] as? Bool) ?? false,
            workspaces: ((json["workspaces"] as? [[String: Any]]) ?? [])
                .compactMap { WorkspaceEntry.from(json: $0) }
                .sorted { ($0.orderIndex, $0.name) < ($1.orderIndex, $1.name) }
        )
    }
}
