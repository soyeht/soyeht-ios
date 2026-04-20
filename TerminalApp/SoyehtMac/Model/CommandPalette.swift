import Foundation

/// A single selectable entry in the command palette (Fase 3.2).
/// Associated values capture everything the selection handler needs to
/// activate the right workspace + focus the right pane.
enum CommandPaletteItem: Hashable {
    case workspace(Workspace)
    case conversation(conversation: Conversation, workspace: Workspace)

    /// Main label (first line in the row).
    var primary: String {
        switch self {
        case .workspace(let ws):
            return ws.name
        case .conversation(let conv, _):
            return conv.handle
        }
    }

    /// Subtitle (dim, second line).
    var secondary: String {
        switch self {
        case .workspace(let ws):
            return ws.branch ?? "workspace"
        case .conversation(let conv, let ws):
            // "<agent> · <workspace name>" reads like a breadcrumb.
            return "\(conv.agent.displayName) · \(ws.name)"
        }
    }

    var workspaceID: Workspace.ID {
        switch self {
        case .workspace(let ws): return ws.id
        case .conversation(_, let ws): return ws.id
        }
    }

    var paneID: Conversation.ID? {
        switch self {
        case .workspace: return nil
        case .conversation(let conv, _): return conv.id
        }
    }
}

/// AppKit-free ranking logic for the command palette. Extracted so unit
/// tests can cover it without pulling in NSWindow/NSPanel.
enum CommandPaletteRanker {

    /// Build the full list of items for the current stores: every workspace
    /// first, then every conversation tagged with its owning workspace.
    /// Workspaces come first because they're the coarser entry — users
    /// typing `proj` usually want the project workspace, not a single pane
    /// inside it.
    static func buildItems(
        workspaces: [Workspace],
        conversations: [Conversation]
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = workspaces.map { .workspace($0) }
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for conv in conversations {
            guard let ws = workspacesByID[conv.workspaceID] else { continue }
            items.append(.conversation(conversation: conv, workspace: ws))
        }
        return items
    }

    /// Rank items against `query`. Empty query returns the original list.
    /// Otherwise: case-insensitive substring match against `primary` or
    /// `secondary`, then ordered by match position (prefix matches first,
    /// primary matches before secondary matches). Items with no match are
    /// filtered out.
    static func rank(items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return items }

        struct Scored {
            let item: CommandPaletteItem
            let score: Int  // lower is better
            let originalIndex: Int
        }

        var scored: [Scored] = []
        for (idx, item) in items.enumerated() {
            let primaryLower = item.primary.lowercased()
            let secondaryLower = item.secondary.lowercased()
            let primaryHit = primaryLower.range(of: trimmed)
            let secondaryHit = secondaryLower.range(of: trimmed)
            // Score: primary hits score 0…1000 based on position;
            // secondary hits score 2000…3000. No hit → drop.
            let score: Int
            if let range = primaryHit {
                let pos = primaryLower.distance(from: primaryLower.startIndex, to: range.lowerBound)
                score = min(pos, 1000)
            } else if let range = secondaryHit {
                let pos = secondaryLower.distance(from: secondaryLower.startIndex, to: range.lowerBound)
                score = 2000 + min(pos, 1000)
            } else {
                continue
            }
            scored.append(Scored(item: item, score: score, originalIndex: idx))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.originalIndex < $1.originalIndex
        }
        return scored.map(\.item)
    }
}
