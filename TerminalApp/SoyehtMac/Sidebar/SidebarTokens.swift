import AppKit

/// Sidebar-specific color tokens + kind-color mapping. Kept separate from
/// `MacTheme` so the sidebar's visual contract can evolve without
/// rippling into pane / window chrome tokens.
///
/// Per SXnc2 V2 the three workspace kinds carry distinct theme-derived
/// accents.
enum SidebarTokens {

    // MARK: - Per-kind accent

    static func accent(for kind: WorkspaceKind) -> NSColor {
        switch kind {
        case .team:         return MacTheme.accentGreenEmerald
        case .worktreeTeam: return MacTheme.accentBlue
        case .adhoc:        return MacTheme.accentAmber
        }
    }

    /// Header fill comes directly from the active terminal theme.
    static func groupHeaderFill(for kind: WorkspaceKind) -> NSColor {
        MacTheme.surfaceBase
    }

    // MARK: - Row selection highlight

    /// Fill applied to the currently-focused conversation row.
    static var selectedRowFill: NSColor { MacTheme.selection }

    /// Left stroke 2pt on the selected row (Pencil `ZS0Xn.stroke`).
    static var selectedRowStroke: NSColor { MacTheme.accentGreenEmerald }

    // MARK: - Text

    /// Handle label when selected (row is active + workspace is active).
    static var handleSelected: NSColor { MacTheme.textPrimary }
    /// Handle label idle.
    static var handleIdle: NSColor { MacTheme.textSecondary }

    /// Workspace group name when that group is the active one in the window.
    static var groupNameActive: NSColor { MacTheme.textPrimary }
    /// Workspace group name when idle.
    static var groupNameIdle: NSColor { MacTheme.textMutedSidebar }

    /// Header "// workspaces" + section labels.
    static var sectionLabel: NSColor { MacTheme.textMutedSidebar }

    /// Muted dot for non-focused rows (Pencil `tAcx2` / `85tgp`).
    static var dotIdle: NSColor { MacTheme.textMutedSidebar }

    // MARK: - Shadow (applied to FloatingSidebarViewController.view.layer)

    static var shadowColor: NSColor { MacTheme.surfaceDeep }
    static let shadowOpacity: Float = 1
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
