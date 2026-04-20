import AppKit

/// Sidebar-specific color tokens + kind-color mapping. Kept separate from
/// `MacTheme` so the sidebar's visual contract can evolve without
/// rippling into pane / window chrome tokens.
///
/// Per SXnc2 V2 the three workspace kinds carry a distinct accent:
/// - `.team`         → emerald (`#10B981`)
/// - `.worktreeTeam` → sky blue (`#5B9CF6`)
/// - `.adhoc`        → amber (`#F59E0B`)
enum SidebarTokens {

    // MARK: - Per-kind accent

    static func accent(for kind: WorkspaceKind) -> NSColor {
        switch kind {
        case .team:         return MacTheme.accentGreenEmerald
        case .worktreeTeam: return MacTheme.accentBlue
        case .adhoc:        return MacTheme.accentAmber
        }
    }

    /// Softer fill derived from the accent (alpha 0.03) — used for the
    /// group's header row so the kind is still legible without dominating.
    static func groupHeaderFill(for kind: WorkspaceKind) -> NSColor {
        accent(for: kind).withAlphaComponent(0.03)
    }

    // MARK: - Row selection highlight

    /// Fill applied to the currently-focused conversation row (green tint
    /// at 0.07 alpha — matches Pencil `ZS0Xn.fill = #10B98112`).
    static let selectedRowFill = MacTheme.accentGreenEmerald.withAlphaComponent(0.07)

    /// Left stroke 2pt on the selected row (Pencil `ZS0Xn.stroke`).
    static let selectedRowStroke = MacTheme.accentGreenEmerald

    // MARK: - Text

    /// Handle label when selected (row is active + workspace is active).
    static let handleSelected = NSColor(calibratedRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    /// Handle label idle.
    static let handleIdle = NSColor(calibratedRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)

    /// Workspace group name when that group is the active one in the window.
    static let groupNameActive = NSColor(calibratedRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    /// Workspace group name when idle.
    static let groupNameIdle = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)

    /// Header "// workspaces" + section labels.
    static let sectionLabel = MacTheme.textMutedSidebar

    /// Muted dot for non-focused rows (Pencil `tAcx2` / `85tgp`).
    static let dotIdle = MacTheme.textMutedSidebar

    // MARK: - Shadow (applied to FloatingSidebarViewController.view.layer)

    static let shadowColor = NSColor.black
    static let shadowOpacity: Float = 0.5
    static let shadowOffset = CGSize(width: 4, height: 0)
    static let shadowRadius: CGFloat = 20
}

/// UserDefaults-backed collapse state for sidebar workspace groups.
enum SidebarCollapseStore {
    private static func key(for id: Workspace.ID) -> String {
        "com.soyeht.mac.sidebar.collapsed.\(id.uuidString)"
    }

    static func isCollapsed(_ id: Workspace.ID) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: id))
    }

    static func setCollapsed(_ id: Workspace.ID, _ collapsed: Bool) {
        UserDefaults.standard.set(collapsed, forKey: key(for: id))
    }

    /// Called by the sidebar when a workspace has been removed from the
    /// store so we don't leak orphan keys over time.
    static func forget(_ id: Workspace.ID) {
        UserDefaults.standard.removeObject(forKey: key(for: id))
    }
}
