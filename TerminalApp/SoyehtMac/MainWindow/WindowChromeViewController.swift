import AppKit

/// Stable content controller for the main window. Hosts the active
/// workspace container as a child and (in Fase 5) the floating sidebar
/// overlay as a sibling subview.
///
/// Before this existed, `SoyehtMainWindowController` swapped
/// `window.contentViewController` directly on every workspace activation
/// and teardown. That made corner-radius / overlay work brittle: every
/// assignment invalidated the view tree that held the rounded mask, and
/// the overlay had no permanent parent. Chrome is permanent; workspace
/// containers are children that come and go.
///
/// Fase 0b keeps this intentionally minimal — transparent bg, no corner
/// radius yet. Fase 4 adds `layer.cornerRadius = 12 + masksToBounds`.
@MainActor
final class WindowChromeViewController: NSViewController {

    private(set) var currentContainer: WorkspaceContainerViewController?
    private(set) var sidebarOverlay: NSViewController?

    /// Design width from SXnc2 `floatSidebar.width` (280pt).
    private static let sidebarWidth: CGFloat = 280

    private var sidebarLeadingConstraint: NSLayoutConstraint?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 920))
        root.wantsLayer = true
        // SXnc2 V2: 12pt rounded corners. Clips overlay + pane content to
        // the rounded rect silhouette. Intentionally ROOT-level clip so the
        // floating sidebar (Fase 5) inherits it automatically.
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = MacTheme.surfaceBase.cgColor
        // The contentView must resize with the window — AppKit doesn't
        // install layout constraints for contentViewController.view, it
        // relies on autoresizing. We still disable autoresize translation
        // on children (they use constraints), but root keeps it.
        root.autoresizingMask = [.width, .height]
        self.view = root
    }

    /// Install (or remove) the floating sidebar overlay. Pinned leading +
    /// top + bottom, 280pt wide. Z-ordered above the workspace container.
    /// Animates with an X slide. Pass `nil` to remove.
    func setSidebarOverlay(_ vc: NSViewController?, animated: Bool = true) {
        // Tear down the current overlay first — we always end in a known
        // clean state, then install the new one if any.
        if let current = sidebarOverlay {
            func finalize() {
                current.view.removeFromSuperview()
                if current.parent === self { current.removeFromParent() }
                if self.sidebarOverlay === current { self.sidebarOverlay = nil }
                self.sidebarLeadingConstraint = nil
            }
            if animated, let leading = sidebarLeadingConstraint {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    ctx.allowsImplicitAnimation = true
                    leading.constant = -Self.sidebarWidth
                    current.view.animator().alphaValue = 0
                    self.view.layoutSubtreeIfNeeded()
                }, completionHandler: { finalize() })
            } else {
                finalize()
            }
        }

        guard let vc = vc, let container = currentContainer else { return }

        addChild(vc)
        let overlay = vc.view
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alphaValue = animated ? 0 : 1
        view.addSubview(overlay) // topmost because added last

        let leading = overlay.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: animated ? -Self.sidebarWidth : 0
        )
        NSLayoutConstraint.activate([
            leading,
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            // Stops above the status bar — container exposes
            // `statusBarTopAnchor` as the public contract.
            overlay.bottomAnchor.constraint(equalTo: container.statusBarTopAnchor),
            overlay.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
        ])
        sidebarOverlay = vc
        sidebarLeadingConstraint = leading
        view.layoutSubtreeIfNeeded()

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                leading.constant = 0
                overlay.animator().alphaValue = 1
                self.view.layoutSubtreeIfNeeded()
            }
        }
    }

    /// Install (or swap) the workspace container as the only pinned child of
    /// this chrome. The container's view is pinned to all edges; any
    /// sidebar overlay stays on top because it's added after.
    func setWorkspaceContainer(_ vc: WorkspaceContainerViewController) {
        if currentContainer === vc { return }

        if let old = currentContainer {
            old.view.removeFromSuperview()
            if old.parent === self { old.removeFromParent() }
        }

        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        // Insert below the sidebar overlay (if any) so z-order stays right
        // when container is swapped while the overlay is open.
        if let overlayView = sidebarOverlay?.view, overlayView.superview === view {
            view.addSubview(vc.view, positioned: .below, relativeTo: overlayView)
        } else {
            view.addSubview(vc.view)
        }
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentContainer = vc
    }
}
