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
    private(set) var topBarView: NSView?

    /// Design width from SXnc2 `floatSidebar.width` (280pt).
    private static let sidebarWidth: CGFloat = 280

    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var containerTopConstraint: NSLayoutConstraint?

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

    func setTopBarView(_ topBar: NSView) {
        if topBarView === topBar { return }

        if let existing = topBarView {
            existing.removeFromSuperview()
        }

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: WindowTopBarView.height),
        ])
        topBarView = topBar

        if let currentContainer {
            containerTopConstraint?.isActive = false
            containerTopConstraint = currentContainer.view.topAnchor.constraint(equalTo: topBar.bottomAnchor)
            containerTopConstraint?.isActive = true
        }
    }

    /// Install (or remove) the floating sidebar overlay. Pinned leading +
    /// top + bottom, 280pt wide. Z-ordered above the workspace container.
    /// Animates with an X slide. Pass `nil` to remove.
    func setSidebarOverlay(_ vc: NSViewController?, animated: Bool = true) {
        // Tear down the current overlay first — we always end in a known
        // clean state, then install the new one if any.
        if let current = sidebarOverlay {
            let finalize = {
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
            overlay.topAnchor.constraint(equalTo: (topBarView?.bottomAnchor ?? view.topAnchor)),
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
        containerTopConstraint?.isActive = false
        containerTopConstraint = vc.view.topAnchor.constraint(equalTo: (topBarView?.bottomAnchor ?? view.topAnchor))
        NSLayoutConstraint.activate([
            containerTopConstraint!,
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentContainer = vc
    }
}

@MainActor
final class WindowTopBarView: NSView {

    static let height: CGFloat = 38

    var onSidebarToggle: (() -> Void)?

    let tabsView: WorkspaceTabsView
    private let sidebarButton = NSButton()
    private let leftInsetGuide = NSView()
    private var leftInsetConstraint: NSLayoutConstraint?

    init(tabsView: WorkspaceTabsView) {
        self.tabsView = tabsView
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = MacTheme.surfaceBase.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Empty areas of the titlebar strip still need to act as a window-drag
    /// region (otherwise users can't move the window by grabbing the top).
    /// Tabs / sidebar button overlay this with their own `hitTest`, so their
    /// clicks short-circuit `mouseDownCanMoveWindow` regardless of this value.
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrafficLightInset()
    }

    func setSidebarButtonTint(_ color: NSColor) {
        sidebarButton.image = Self.makeSidebarGlyph(tint: color)
    }

    private func build() {
        leftInsetGuide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftInsetGuide)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.isBordered = false
        sidebarButton.bezelStyle = .inline
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.image = Self.makeSidebarGlyph(tint: MacTheme.accentBlue)
        sidebarButton.contentTintColor = nil
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarTapped)
        sidebarButton.setAccessibilityLabel(String(localized: "chrome.button.sidebar.a11y", comment: "VoiceOver label for the sidebar-toggle button in the window chrome."))
        addSubview(sidebarButton)

        tabsView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabsView)

        leftInsetConstraint = leftInsetGuide.widthAnchor.constraint(equalToConstant: 86)
        leftInsetConstraint?.isActive = true

        // Traffic lights stay top-LEFT in absolute terms even under RTL (macOS convention —
        // window controls are direction-independent, mirroring the minimize/close stays on the
        // same side of the chrome regardless of language). So `leftInsetGuide` reserves
        // physical left-side space and uses `leftAnchor` (absolute), not `leadingAnchor`.
        // Content flow (sidebarButton + tabsView) mirrors based on layout direction so the
        // tab strip flows from the trailing edge toward the traffic lights.
        //
        // On macOS, `NSApp.userInterfaceLayoutDirection` only reflects RTL when the SYSTEM
        // language is RTL. For our `-AppleLanguages '(ar)'` runtime override, it stays LTR.
        // We check the active language's character direction directly — more reliable for
        // both production (system RTL) and testing (runtime override).
        let isRTL: Bool = {
            let langID = Locale.current.language.languageCode?.identifier
                ?? Locale.preferredLanguages.first
                ?? "en"
            return NSLocale.characterDirection(forLanguage: langID) == .rightToLeft
        }()

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            leftInsetGuide.leftAnchor.constraint(equalTo: leftAnchor),
            leftInsetGuide.topAnchor.constraint(equalTo: topAnchor),
            leftInsetGuide.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 20),
            sidebarButton.heightAnchor.constraint(equalToConstant: 20),

            tabsView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if isRTL {
            // RTL: sidebarButton at absolute right edge; tabs flow from sidebar to the left,
            // bounded on the absolute left by leftInsetGuide so tabs never collide with traffic lights.
            NSLayoutConstraint.activate([
                sidebarButton.rightAnchor.constraint(equalTo: rightAnchor, constant: -10),
                tabsView.rightAnchor.constraint(equalTo: sidebarButton.leftAnchor, constant: -14),
                tabsView.leftAnchor.constraint(greaterThanOrEqualTo: leftInsetGuide.rightAnchor, constant: 16),
            ])
        } else {
            // LTR (original behavior): sidebarButton right after leftInsetGuide, tabs fill to the right.
            NSLayoutConstraint.activate([
                sidebarButton.leftAnchor.constraint(equalTo: leftInsetGuide.rightAnchor, constant: 10),
                tabsView.leftAnchor.constraint(equalTo: sidebarButton.rightAnchor, constant: 14),
                tabsView.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor, constant: -16),
            ])
        }
    }

    private func updateTrafficLightInset() {
        guard let window,
              let zoom = window.standardWindowButton(.zoomButton)
        else { return }

        let zoomFrameInWindow = zoom.convert(zoom.bounds, to: nil)
        let zoomFrameInSelf = convert(zoomFrameInWindow, from: nil)
        leftInsetConstraint?.constant = max(78, zoomFrameInSelf.maxX + 14)
    }

    @objc private func sidebarTapped() {
        onSidebarToggle?()
    }

    @discardableResult
    func handleFallbackClick(
        mouseDownLocationInWindow down: NSPoint,
        mouseUpLocationInWindow up: NSPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let downPoint = convert(down, from: nil)
        let upPoint = convert(up, from: nil)
        let dx = upPoint.x - downPoint.x
        let dy = upPoint.y - downPoint.y
        guard (dx * dx + dy * dy) < 16 else { return false }
        guard bounds.contains(upPoint) else { return false }

        if sidebarButton.frame.insetBy(dx: -4, dy: -4).contains(upPoint) {
            onSidebarToggle?()
            return true
        }

        return tabsView.handleFallbackClick(atWindowPoint: up, modifiers: modifiers)
    }

    /// Look up the workspace tab under a window-local point (Fase 4.1 drag
    /// fallback). Returns the tab's workspace ID or nil if the point isn't
    /// over a tab body.
    func tabID(atWindowPoint point: NSPoint) -> Workspace.ID? {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        return tabsView.tabID(atWindowPoint: point)
    }

    /// Drag-phase forwarder for the titlebar drag fallback. Used when a
    /// real mouse drag starts on a tab that happens to sit in AppKit's
    /// native titlebar drag region (Fase 4.1 — without this, AppKit
    /// intercepts the drag and moves the whole window).
    func routeTabReorderDrag(draggedID: Workspace.ID, atWindowPoint point: NSPoint, phase: WorkspaceTabsView.LocalTabDragPhase) {
        tabsView.handleReorderDrag(draggedID: draggedID, atWindowPoint: point, phase: phase)
    }

    private static func makeSidebarGlyph(tint: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        defer { image.unlockFocus() }

        tint.setStroke()
        tint.setFill()

        let line = NSBezierPath()
        line.lineWidth = 1.15
        line.lineCapStyle = .round

        [(5.5, 11.0), (5.5, 7.0), (5.5, 3.0)].forEach { x, y in
            line.move(to: NSPoint(x: 1.8, y: y))
            line.line(to: NSPoint(x: CGFloat(x), y: CGFloat(y)))
        }
        line.move(to: NSPoint(x: 5.5, y: 10.8))
        line.line(to: NSPoint(x: 8.3, y: 8.7))
        line.move(to: NSPoint(x: 5.5, y: 7.0))
        line.line(to: NSPoint(x: 8.3, y: 7.0))
        line.move(to: NSPoint(x: 5.5, y: 3.2))
        line.line(to: NSPoint(x: 8.3, y: 5.3))
        line.stroke()

        [NSRect(x: 0.9, y: 10.0, width: 1.8, height: 1.8),
         NSRect(x: 0.9, y: 6.1, width: 1.8, height: 1.8),
         NSRect(x: 0.9, y: 2.2, width: 1.8, height: 1.8),
         NSRect(x: 8.8, y: 7.8, width: 4.1, height: 2.0),
         NSRect(x: 8.8, y: 6.0, width: 4.1, height: 2.0),
         NSRect(x: 8.8, y: 4.2, width: 4.1, height: 2.0)]
            .forEach { rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: 0.6, yRadius: 0.6)
                path.lineWidth = 1.0
                path.stroke()
            }

        image.isTemplate = false
        return image
    }
}
