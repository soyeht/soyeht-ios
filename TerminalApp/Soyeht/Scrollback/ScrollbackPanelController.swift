import UIKit
import SoyehtCore
import SwiftTerm

// Coordinator that owns the scrollback panel and wires it to the active
// `TerminalView`:
//
//   - attaches as the view's `contentObserver` so the panel knows when the
//     live terminal emits new output and can refetch tmux history (only
//     while actually visible — peek is cheap, full fetches);
//   - hydrates content via `TmuxHistorySource` (the single source of truth
//     for rendered lines) and reconciles `displayedLines` through a minimal
//     diff applied as `performBatchUpdates`, preserving scroll position;
//   - drives the two-detent pan gesture on the drag handle, with
//     rubber-band feedback past the limits and velocity-projected snap;
//   - exposes a tappable button on the handle as the VoiceOver / Switch
//     Control alternative to dragging;
//   - invalidates the collection layout and refetches on font-size change
//     so Dynamic Type / user font changes take effect immediately.
@MainActor
final class ScrollbackPanelController: NSObject {
    enum Detent {
        case peek, full
    }

    private weak var hostView: UIView?
    private weak var terminalView: TerminalView?

    private(set) var panelView: ScrollbackPanelView?
    private let tmuxSource = TmuxHistorySource()
    /// What the collection view currently shows. Kept in sync with
    /// `tmuxSource.lines` through a diff-based update so UIKit can preserve
    /// the scroll position across refreshes.
    private var displayedLines: [NSAttributedString] = []
    private var heightConstraint: NSLayoutConstraint?
    private var fontObserver: NSObjectProtocol?
    private var activePaneObserver: NSObjectProtocol?
    private var pendingActivePaneReloadTask: Task<Void, Never>?
    private var fullReloadsRemaining = 0
    private var suppressLiveReloadUntil = Date.distantPast

    private var currentDetent: Detent = .peek
    private var heightAtBegan: CGFloat = 0
    private var activeAnimator: UIViewPropertyAnimator?

    // Tunables
    private let flickVelocityThreshold: CGFloat = 1800
    private let overshootAllowance: CGFloat = 60
    private let projectionFactor: CGFloat = 0.3
    private let tapAnimationDuration: TimeInterval = 0.4
    private let activePaneReloadDelays: [Duration] = [.milliseconds(250), .milliseconds(650)]
    private let liveReloadSuppressionWindow: TimeInterval = 1.0

    // MARK: - Lifecycle

    func attach(to host: UIView, terminalView: TerminalView, topAnchor: NSLayoutYAxisAnchor) {
        detach()

        self.hostView = host
        self.terminalView = terminalView

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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.handleView.addGestureRecognizer(pan)

        panel.handleView.tapButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        updateAccessibility(for: .peek)

        tmuxSource.onUpdate = { [weak self] in
            self?.applyTmuxLines()
        }

        terminalView.contentObserver = self

        fontObserver = NotificationCenter.default.addObserver(
            forName: .soyehtFontSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleFontSizeChanged() }
        }

        activePaneObserver = NotificationCenter.default.addObserver(
            forName: .soyehtActivePaneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleActivePaneChanged(note) }
        }
    }

    func detach() {
        if let observer = fontObserver {
            NotificationCenter.default.removeObserver(observer)
            fontObserver = nil
        }
        if let observer = activePaneObserver {
            NotificationCenter.default.removeObserver(observer)
            activePaneObserver = nil
        }
        pendingActivePaneReloadTask?.cancel()
        pendingActivePaneReloadTask = nil
        activeAnimator?.stopAnimation(true)
        activeAnimator = nil
        if let tv = terminalView, tv.contentObserver === self {
            tv.contentObserver = nil
        }
        tmuxSource.cancel()
        panelView?.removeFromSuperview()
        panelView = nil
        heightConstraint = nil
        hostView = nil
        terminalView = nil
    }

    /// Sets the tmux container/session used to fetch the pane history the
    /// panel renders. Safe to call before or after `attach`.
    func setTmuxContext(container: String, session: String, serverContext: ServerContext) {
        tmuxSource.container = container
        tmuxSource.session = session
        tmuxSource.context = serverContext
        fullReloadsRemaining = max(fullReloadsRemaining, 1)
        // If the panel is already expanded, refresh right away so the user
        // sees the updated pane without having to re-open it.
        if currentDetent != .peek {
            tmuxSource.load()
        }
    }

    // MARK: - Active pane sync

    private func handleActivePaneChanged(_ note: Notification) {
        guard shouldHandleActivePaneNotification(note) else { return }
        // A pane switch replaces the entire history document, not an
        // incremental tail append. Force the next couple of updates down the
        // full reload path so visible cells are always rebound to the new pane.
        // Also suppress generic live-terminal reloads briefly so transient
        // output during the switch can't overwrite the final pane selection.
        fullReloadsRemaining = max(fullReloadsRemaining, activePaneReloadDelays.count + 1)
        suppressLiveReloadUntil = Date().addingTimeInterval(liveReloadSuppressionWindow)
        reloadHistoryIfVisible()
        scheduleDeferredActivePaneReloads()
    }

    /// Scope filter: only react if the notification's container+session match
    /// the context this controller is currently bound to. Prevents a controller
    /// attached to one session from reloading when a different session switches
    /// panes. Exposed `internal` for unit tests.
    internal func shouldHandleActivePaneNotification(_ note: Notification) -> Bool {
        let container = note.userInfo?[SoyehtNotificationKey.container] as? String
        let session = note.userInfo?[SoyehtNotificationKey.session] as? String
        return container != nil
            && session != nil
            && container == tmuxSource.container
            && session == tmuxSource.session
    }

    /// Reload tmux history if the panel is currently revealed. Mirrors the
    /// existing `currentDetent != .peek` gate used by `setTmuxContext`, snap,
    /// and `terminalContentDidChange`. Exposed `internal` for unit tests.
    internal func reloadHistoryIfVisible() {
        guard currentDetent != .peek else { return }
        tmuxSource.load()
    }

    /// `select-pane` can complete just before the backend's active-pane state
    /// is fully visible to a follow-up `capture-pane` request. Keep the
    /// immediate reload for responsiveness, then issue a couple of short
    /// deferred reloads; the source's request-id gate ensures only the latest
    /// response wins.
    private func scheduleDeferredActivePaneReloads() {
        guard currentDetent != .peek else { return }
        pendingActivePaneReloadTask?.cancel()
        let delays = activePaneReloadDelays
        pendingActivePaneReloadTask = Task { @MainActor [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.tmuxSource.load()
            }
        }
    }

    private func shouldSuppressLiveReloads() -> Bool {
        Date() < suppressLiveReloadUntil
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

        case .changed:
            let translation = pan.translation(in: host)
            heightC.constant = clampWithRubberBand(heightAtBegan + translation.y)
            host.layoutIfNeeded()
            updatePanelReveal(forHeight: heightC.constant)

        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: host).y
            let target = projectedDetent(velocity: velocity)
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
        if detent == .peek {
            pendingActivePaneReloadTask?.cancel()
            pendingActivePaneReloadTask = nil
        }

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
        animator.startAnimation()
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

    // MARK: - Font / layout

    private func handleFontSizeChanged() {
        panelView?.collectionView.collectionViewLayout.invalidateLayout()
        fullReloadsRemaining = max(fullReloadsRemaining, 1)
        // Re-fetch so AnsiTextParser re-runs with the updated font size.
        tmuxSource.load()
    }

    // MARK: - Tmux history diff

    /// Reconciles `displayedLines` with the source's latest lines using a
    /// minimal diff applied via `performBatchUpdates`. This keeps the user's
    /// scroll position stable: lines inserted elsewhere in the array push
    /// existing cells but the visible cell stays on the same pixel. If the
    /// user was parked at the very bottom (reading the tail), we re-pin to
    /// the bottom after the update so the latest line stays in view.
    ///
    /// Diff is computed against `.string` only; style-only changes don't
    /// force a replace. Acceptable trade-off — in a terminal, text rarely
    /// changes color without also changing characters, and preserving cells
    /// beats re-rendering every visible row on each refetch.
    private func applyTmuxLines() {
        guard let panel = panelView else { return }
        let new = tmuxSource.lines
        let wasAtBottom = isScrolledToBottom(panel.collectionView)

        if fullReloadsRemaining > 0 {
            fullReloadsRemaining -= 1
            displayedLines = new
            panel.collectionView.reloadData()
            panel.collectionView.layoutIfNeeded()
            if wasAtBottom {
                scrollToBottom(animated: false)
            }
            return
        }

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
            // Only refetch while the panel is actually visible — saves a
            // burst of HTTP requests when the user isn't looking. The
            // sequence number in TmuxHistorySource drops stale responses.
            // During active-pane handoff, pane-specific reloads take priority
            // over live output churn.
            if self.currentDetent != .peek, !self.shouldSuppressLiveReloads() {
                self.tmuxSource.load()
            }
        }
    }

    nonisolated func terminalTitleDidChange(terminal: Terminal, title: String) {
        // Not relevant to the scrollback panel.
    }

    nonisolated func terminalDidResize(terminal: Terminal, cols: Int, rows: Int) {
        MainActor.assumeIsolated {
            self.panelView?.collectionView.collectionViewLayout.invalidateLayout()
            if !self.shouldSuppressLiveReloads() {
                self.tmuxSource.load()
            }
        }
    }
}
