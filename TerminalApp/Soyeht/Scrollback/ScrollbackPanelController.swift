import UIKit
import SwiftTerm
import os

// Coordinator that owns the scrollback panel and wires it to the active
// `TerminalView`:
//
//   - attaches as the view's `contentObserver` so the collection view updates
//     on every terminal content change (coalesced to 60fps by SwiftTerm);
//   - translates store deltas into `performBatchUpdates` insert/delete ops;
//   - drives the three-detent pan gesture on the drag handle, with
//     rubber-band feedback past the limits and velocity-projected snap;
//   - exposes a tappable chevron as the VoiceOver / Switch Control
//     alternative to dragging;
//   - pauses history updates while the terminal is in the alternate buffer
//     (vim / less), showing an inline badge explaining why;
//   - invalidates and reloads the rendering cache on font-size changes so
//     Dynamic Type and user-driven font changes take effect immediately.
@MainActor
final class ScrollbackPanelController: NSObject {

    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "scrollback")

    enum Detent {
        case peek, full
    }

    private weak var hostView: UIView?
    private weak var terminalView: TerminalView?

    private(set) var panelView: ScrollbackPanelView?
    private var store: ScrollbackStore?
    private let tmuxSource = TmuxHistorySource()
    /// What the collection view currently shows. Kept in sync with
    /// `tmuxSource.lines` through a diff-based update so UIKit can preserve
    /// the scroll position across refreshes.
    private var displayedLines: [NSAttributedString] = []
    private var heightConstraint: NSLayoutConstraint?
    private var fontObserver: NSObjectProtocol?

    // Populated by store.onPrune/onAppend during refresh() so applyRefresh
    // can translate a refresh into a single performBatchUpdates.
    private var pendingRemoved = 0
    private var pendingAppended = 0

    private var currentDetent: Detent = .peek
    private var heightAtBegan: CGFloat = 0
    private var activeAnimator: UIViewPropertyAnimator?
    private var isInAlternateBuffer = false

    // Tunables
    private let flickVelocityThreshold: CGFloat = 1800
    private let overshootAllowance: CGFloat = 60
    private let projectionFactor: CGFloat = 0.3
    private let tapAnimationDuration: TimeInterval = 0.4
    private let geometryDriftThreshold: CGFloat = 0.5

    // MARK: - Lifecycle

    func attach(to host: UIView, terminalView: TerminalView, topAnchor: NSLayoutYAxisAnchor) {
        detach()

        self.hostView = host
        self.terminalView = terminalView

        let store = ScrollbackStore(terminal: terminalView.getTerminal())
        self.store = store

        let panel = ScrollbackPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.collectionView.dataSource = self
        panel.collectionView.delegate = self
        host.addSubview(panel)

        // Keep the panel pinned to the host's top edge rather than to the
        // TerminalView/UIScrollView itself. Anchoring to the scroll view can
        // track scroll/content animations and briefly expose the live terminal
        // under the tabs during release/snap.
        let height = panel.heightAnchor.constraint(equalToConstant: peekHeight())
        heightConstraint = height
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            height
        ])
        // Ensure we render over SwiftTerm's Metal layer regardless of when
        // subviews were added.
        host.bringSubviewToFront(panel)
        panel.layer.zPosition = 100
        self.panelView = panel
        host.layoutIfNeeded()
        updatePanelReveal(forHeight: height.constant)
        logGeometry("attach")

        store.onPrune = { [weak self] n in self?.pendingRemoved += n }
        store.onAppend = { [weak self] n in self?.pendingAppended += n }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.handleView.addGestureRecognizer(pan)

        panel.handleView.tapButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        updateAccessibility(for: .peek)

        isInAlternateBuffer = terminalView.getTerminal().isCurrentBufferAlternate

        tmuxSource.onUpdate = { [weak self] in
            self?.applyTmuxLines()
        }

        applyRefresh(initial: true)

        terminalView.contentObserver = self

        fontObserver = NotificationCenter.default.addObserver(
            forName: .soyehtFontSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleFontSizeChanged() }
        }
    }

    func detach() {
        if let observer = fontObserver {
            NotificationCenter.default.removeObserver(observer)
            fontObserver = nil
        }
        activeAnimator?.stopAnimation(true)
        activeAnimator = nil
        if let tv = terminalView, tv.contentObserver === self {
            tv.contentObserver = nil
        }
        tmuxSource.cancel()
        panelView?.removeFromSuperview()
        panelView = nil
        heightConstraint = nil
        store = nil
        hostView = nil
        terminalView = nil
    }

    /// Sets the tmux container/session used to fetch the pane history the
    /// panel renders. Safe to call before or after `attach`.
    func setTmuxContext(container: String, session: String) {
        tmuxSource.container = container
        tmuxSource.session = session
        // If the panel is already expanded, refresh right away so the user
        // sees the updated pane without having to re-open it.
        if currentDetent != .peek {
            tmuxSource.load()
        }
    }

    // MARK: - Detents

    private func peekHeight() -> CGFloat {
        ScrollbackDragHandleView.height + 8
    }

    private func fullHeight() -> CGFloat {
        max(peekHeight() + 80, (hostView?.bounds.height ?? 0) * 0.75)
    }

    private func height(for detent: Detent) -> CGFloat {
        switch detent {
        case .peek: return peekHeight()
        case .full: return fullHeight()
        }
    }

    private func clampWithRubberBand(_ raw: CGFloat) -> CGFloat {
        let lower = peekHeight()
        let upper = fullHeight()
        if raw < lower {
            return lower + RubberBand.offset(rawOffset: raw - lower, dimension: overshootAllowance)
        }
        if raw > upper {
            return upper + RubberBand.offset(rawOffset: raw - upper, dimension: overshootAllowance)
        }
        return raw
    }

    // MARK: - Gestures / actions

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let host = hostView, let heightC = heightConstraint else { return }

        switch pan.state {
        case .began:
            activeAnimator?.stopAnimation(false)
            activeAnimator?.finishAnimation(at: .current)
            activeAnimator = nil
            heightAtBegan = heightC.constant
            logGeometry("pan began")

        case .changed:
            let translation = pan.translation(in: host)
            heightC.constant = clampWithRubberBand(heightAtBegan + translation.y)
            host.layoutIfNeeded()
            updatePanelReveal(forHeight: heightC.constant)
            logIfGeometryDrifted(event: "pan changed")

        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: host).y
            let target = projectedDetent(velocity: velocity)
            logGeometry("pan ended target=\(string(for: target)) velocity=\(String(format: "%.2f", velocity))")
            snap(to: target, velocity: velocity, host: host)

        default:
            break
        }
    }

    @objc private func handleTap() {
        guard let host = hostView else { return }
        let next: Detent = currentDetent == .peek ? .full : .peek
        snap(to: next, velocity: 0, host: host)
    }

    private func projectedDetent(velocity: CGFloat) -> Detent {
        if velocity > flickVelocityThreshold { return .full }
        if velocity < -flickVelocityThreshold { return .peek }

        let current = heightConstraint?.constant ?? peekHeight()
        let projection = current + velocity * projectionFactor
        let candidates: [(Detent, CGFloat)] = [
            (.peek, peekHeight()),
            (.full, fullHeight())
        ]
        return candidates.min(by: { abs($0.1 - projection) < abs($1.1 - projection) })?.0 ?? currentDetent
    }

    private func snap(to detent: Detent, velocity: CGFloat, host: UIView) {
        guard let heightC = heightConstraint else { return }
        let target = height(for: detent)
        _ = velocity

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let detentChanged = detent != currentDetent

        // Avoid spring overshoot here. The panel must stay glued to the top
        // edge while snapping; a spring can briefly reveal a strip of the live
        // terminal during release.
        let timing = UICubicTimingParameters(animationCurve: .easeOut)
        let animator = UIViewPropertyAnimator(
            duration: reduceMotion ? 0.2 : tapAnimationDuration * 0.55,
            timingParameters: timing
        )

        animator.addAnimations {
            heightC.constant = target
            host.layoutIfNeeded()
            self.panelView?.setContentRevealProgress(self.revealProgress(forHeight: target))
        }
        animator.addCompletion { [weak self] _ in
            heightC.constant = target
            host.layoutIfNeeded()
            self?.updatePanelReveal(forHeight: target)
            self?.logGeometry("snap completion detent=\(self?.string(for: detent) ?? "unknown")")
            if self?.activeAnimator === animator {
                self?.activeAnimator = nil
            }
        }

        if detentChanged, !reduceMotion {
            let gen = UIImpactFeedbackGenerator(style: .soft)
            gen.prepare()
            gen.impactOccurred()
        }

        let wasCollapsed = currentDetent == .peek
        currentDetent = detent
        updateAccessibility(for: detent)

        // Fetch tmux pane history as soon as the user expands the panel,
        // so the latest content is ready by the time the animation finishes.
        // Jump the scroll to the bottom immediately — even before the
        // response arrives — so the user sees the tail as soon as cells
        // start rendering.
        if wasCollapsed && detent != .peek {
            tmuxSource.load()
            scrollToBottom(animated: false)
        }

        activeAnimator = animator
        logGeometry("snap start detent=\(string(for: detent)) target=\(String(format: "%.2f", target))")
        animator.startAnimation()
        scheduleSnapTrace(detent: detent)
    }

    private func string(for detent: Detent) -> String {
        switch detent {
        case .peek: return "peek"
        case .full: return "full"
        }
    }

    private func expectedPanelTop() -> CGFloat {
        hostView?.safeAreaInsets.top ?? 0
    }

    private func revealProgress(forHeight height: CGFloat) -> CGFloat {
        let minHeight = peekHeight()
        let maxHeight = fullHeight()
        guard maxHeight > minHeight else { return 1 }
        return max(0, min(1, (height - minHeight) / (maxHeight - minHeight)))
    }

    private func updatePanelReveal(forHeight height: CGFloat) {
        panelView?.setContentRevealProgress(revealProgress(forHeight: height))
    }

    private func logIfGeometryDrifted(event: String) {
        guard let panel = panelView else { return }
        let drift = abs(panel.frame.minY - expectedPanelTop())
        guard drift > geometryDriftThreshold else { return }
        logGeometry("\(event) drift=\(String(format: "%.2f", drift))")
    }

    private func scheduleSnapTrace(detent: Detent) {
        let checkpoints: [TimeInterval] = [0.0, 0.05, 0.10, 0.16, 0.22]
        for delay in checkpoints {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.logIfGeometryDrifted(
                        event: "snap trace detent=\(self.string(for: detent)) t=\(String(format: "%.2f", delay))"
                    )
                }
            }
        }
    }

    private func logGeometry(_ event: String) {
        guard let panel = panelView, let host = hostView else { return }

        let presentationFrame = panel.layer.presentation()?.frame ?? panel.frame
        let collectionFrame = panel.collectionView.frame
        let terminalFrame = terminalView?.frame ?? .zero
        let height = heightConstraint?.constant ?? 0
        let expectedTop = expectedPanelTop()
        let drift = panel.frame.minY - expectedTop
        let message = """
        [scrollback] \(event) panel=\(NSCoder.string(for: panel.frame)) \
        presentation=\(NSCoder.string(for: presentationFrame)) \
        collection=\(NSCoder.string(for: collectionFrame)) \
        terminal=\(NSCoder.string(for: terminalFrame)) \
        host=\(NSCoder.string(for: host.bounds)) \
        heightC=\(String(format: "%.2f", height)) \
        expectedTop=\(String(format: "%.2f", expectedTop)) \
        drift=\(String(format: "%.2f", drift))
        """
        Self.logger.debug("\(message, privacy: .public)")
    }

    private func updateAccessibility(for detent: Detent) {
        guard let button = panelView?.handleView.tapButton else { return }
        button.accessibilityLabel = "Scrollback panel"
        switch detent {
        case .peek:
            button.accessibilityValue = "collapsed"
            button.accessibilityHint = "Double tap to expand"
        case .full:
            button.accessibilityValue = "expanded"
            button.accessibilityHint = "Double tap to collapse"
        }
    }

    // MARK: - Data refresh

    private func applyRefresh(initial: Bool = false) {
        guard let panel = panelView, let store = store else { return }

        // While the app is in the alternate buffer (vim/less) the scrollback
        // snapshot shouldn't mutate — the normal buffer's ring is intact but
        // unrelated to what the user is doing. Freeze the view.
        if isInAlternateBuffer, !initial { return }

        pendingRemoved = 0
        pendingAppended = 0
        store.refresh()
        let removed = pendingRemoved
        let appended = pendingAppended

        if initial {
            panel.collectionView.reloadData()
            return
        }
        if removed == 0 && appended == 0 { return }

        let newCount = store.count
        panel.collectionView.performBatchUpdates {
            if removed > 0 {
                let deletions = (0 ..< removed).map { IndexPath(item: $0, section: 0) }
                panel.collectionView.deleteItems(at: deletions)
            }
            if appended > 0 {
                let start = newCount - appended
                let insertions = (start ..< newCount).map { IndexPath(item: $0, section: 0) }
                panel.collectionView.insertItems(at: insertions)
            }
        }
    }

    private func updateAlternateBufferState() {
        guard let terminal = terminalView?.getTerminal(), let panel = panelView else { return }
        let nowAlt = terminal.isCurrentBufferAlternate
        if nowAlt == isInAlternateBuffer { return }

        isInAlternateBuffer = nowAlt

        if !nowAlt {
            // Returning to normal buffer: reconcile any changes we skipped.
            store?.invalidate()
            pendingRemoved = 0
            pendingAppended = 0
            store?.refresh()
            panel.collectionView.reloadData()
        }
    }

    private func handleFontSizeChanged() {
        guard let panel = panelView, let store = store else { return }
        store.fontSize = TerminalPreferences.shared.fontSize
        store.invalidate()
        panel.collectionView.collectionViewLayout.invalidateLayout()
        panel.collectionView.reloadData()
    }

    // MARK: - Tmux history diff

    /// Reconciles `displayedLines` with the source's latest lines using a
    /// minimal diff applied via `performBatchUpdates`. This keeps the user's
    /// scroll position stable: lines inserted elsewhere in the array push
    /// existing cells but the visible cell stays on the same pixel. If the
    /// user was parked at the very bottom (reading the tail), we re-pin to
    /// the bottom after the update so the latest line stays in view.
    private func applyTmuxLines() {
        guard let panel = panelView else { return }
        let new = tmuxSource.lines
        let wasAtBottom = isScrolledToBottom(panel.collectionView)

        let oldStrings = displayedLines.map { $0.string }
        let newStrings = new.map { $0.string }
        let diff = newStrings.difference(from: oldStrings)

        var deletes: [IndexPath] = []
        var inserts: [IndexPath] = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                deletes.append(IndexPath(item: offset, section: 0))
            case .insert(let offset, _, _):
                inserts.append(IndexPath(item: offset, section: 0))
            }
        }

        displayedLines = new

        if deletes.isEmpty && inserts.isEmpty { return }

        panel.collectionView.performBatchUpdates({
            if !deletes.isEmpty { panel.collectionView.deleteItems(at: deletes) }
            if !inserts.isEmpty { panel.collectionView.insertItems(at: inserts) }
        }, completion: { [weak self] _ in
            if wasAtBottom {
                self?.scrollToBottom(animated: false)
            }
        })
    }

    private func isScrolledToBottom(_ collectionView: UICollectionView, threshold: CGFloat = 30) -> Bool {
        let y = collectionView.contentOffset.y
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        // Empty content also counts as "at the bottom" — we want to pin.
        return collectionView.contentSize.height <= collectionView.bounds.height
            || y >= maxY - threshold
    }

    private func scrollToBottom(animated: Bool) {
        guard let panel = panelView else { return }
        let cv = panel.collectionView
        guard !displayedLines.isEmpty else { return }
        let last = IndexPath(item: displayedLines.count - 1, section: 0)
        cv.scrollToItem(at: last, at: .bottom, animated: animated)
    }
}

// MARK: - Data source / delegate

extension ScrollbackPanelController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedLines.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ScrollbackLineCell.reuseID, for: indexPath)
        if let typedCell = cell as? ScrollbackLineCell,
           indexPath.item >= 0 && indexPath.item < displayedLines.count {
            typedCell.configure(attributed: displayedLines[indexPath.item])
        }
        return cell
    }
}

extension ScrollbackPanelController: UICollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let height = TerminalPreferences.shared.fontSize + 4
        return CGSize(width: collectionView.bounds.width, height: height)
    }
}

// MARK: - Gesture delegate

extension ScrollbackPanelController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only accept mostly-vertical motion so horizontal swipes fall through
        // to other recognizers (e.g. swipe-between-tmux-panes on the terminal).
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: hostView)
        return abs(velocity.y) > abs(velocity.x)
    }
}

// MARK: - TerminalContentObserverDelegate

extension ScrollbackPanelController: TerminalContentObserverDelegate {

    nonisolated func terminalContentDidChange(terminal: Terminal, startRow: Int, endRow: Int) {
        MainActor.assumeIsolated {
            self.updateAlternateBufferState()
            self.applyRefresh()
            // Only refetch while the panel is actually visible — saves a
            // burst of HTTP requests when the user isn't looking. The
            // sequence number in TmuxHistorySource drops stale responses.
            if self.currentDetent != .peek {
                self.tmuxSource.load()
            }
        }
    }

    nonisolated func terminalTitleDidChange(terminal: Terminal, title: String) {
        // Not relevant to the scrollback panel.
    }

    nonisolated func terminalDidResize(terminal: Terminal, cols: Int, rows: Int) {
        MainActor.assumeIsolated {
            self.store?.invalidate()
            self.pendingRemoved = 0
            self.pendingAppended = 0
            self.store?.refresh()
            self.panelView?.collectionView.reloadData()
        }
    }
}
