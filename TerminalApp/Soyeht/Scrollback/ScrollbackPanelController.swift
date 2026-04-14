import UIKit
import SwiftTerm

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

    enum Detent {
        case peek, mid, full
    }

    private weak var hostView: UIView?
    private weak var terminalView: TerminalView?

    private(set) var panelView: ScrollbackPanelView?
    private var store: ScrollbackStore?
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
    private let springDamping: CGFloat = 0.86
    private let tapAnimationDuration: TimeInterval = 0.4

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

        let height = panel.heightAnchor.constraint(equalToConstant: peekHeight())
        heightConstraint = height
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            height
        ])
        self.panelView = panel

        store.onPrune = { [weak self] n in self?.pendingRemoved += n }
        store.onAppend = { [weak self] n in self?.pendingAppended += n }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.handleView.addGestureRecognizer(pan)

        panel.handleView.tapButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        updateAccessibility(for: .peek)

        isInAlternateBuffer = terminalView.getTerminal().isCurrentBufferAlternate

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
        panelView?.removeFromSuperview()
        panelView = nil
        heightConstraint = nil
        store = nil
        hostView = nil
        terminalView = nil
    }

    // MARK: - Detents

    private func peekHeight() -> CGFloat {
        ScrollbackDragHandleView.height + 8
    }

    private func midHeight() -> CGFloat {
        max(peekHeight() + 40, (hostView?.bounds.height ?? 0) * 0.3)
    }

    private func fullHeight() -> CGFloat {
        max(peekHeight() + 80, (hostView?.bounds.height ?? 0) * 0.8)
    }

    private func height(for detent: Detent) -> CGFloat {
        switch detent {
        case .peek: return peekHeight()
        case .mid: return midHeight()
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
            activeAnimator?.stopAnimation(true)
            activeAnimator = nil
            heightAtBegan = heightC.constant

        case .changed:
            let translation = pan.translation(in: host)
            heightC.constant = clampWithRubberBand(heightAtBegan + translation.y)

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
        let next: Detent
        switch currentDetent {
        case .peek: next = .mid
        case .mid:  next = .full
        case .full: next = .peek
        }
        snap(to: next, velocity: 0, host: host)
    }

    private func projectedDetent(velocity: CGFloat) -> Detent {
        if velocity > flickVelocityThreshold {
            switch currentDetent {
            case .peek: return .mid
            case .mid, .full: return .full
            }
        }
        if velocity < -flickVelocityThreshold {
            switch currentDetent {
            case .full: return .mid
            case .mid, .peek: return .peek
            }
        }

        let current = heightConstraint?.constant ?? peekHeight()
        let projection = current + velocity * projectionFactor

        let candidates: [(Detent, CGFloat)] = [
            (.peek, peekHeight()),
            (.mid, midHeight()),
            (.full, fullHeight())
        ]
        return candidates.min(by: { abs($0.1 - projection) < abs($1.1 - projection) })?.0 ?? currentDetent
    }

    private func snap(to detent: Detent, velocity: CGFloat, host: UIView) {
        guard let heightC = heightConstraint else { return }
        let target = height(for: detent)
        let current = heightC.constant
        let distance = target - current

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let detentChanged = detent != currentDetent

        // Animator — spring with velocity when motion allowed, plain timed curve otherwise.
        let animator: UIViewPropertyAnimator
        if reduceMotion {
            let timing = UICubicTimingParameters(animationCurve: .easeInOut)
            animator = UIViewPropertyAnimator(duration: 0.25, timingParameters: timing)
        } else {
            let normalizedY: CGFloat = abs(distance) > 0.5 ? (velocity / distance) : 0
            let spring = UISpringTimingParameters(
                dampingRatio: springDamping,
                initialVelocity: CGVector(dx: 0, dy: normalizedY)
            )
            animator = UIViewPropertyAnimator(duration: tapAnimationDuration, timingParameters: spring)
        }

        animator.addAnimations {
            heightC.constant = target
            host.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            if self?.activeAnimator === animator {
                self?.activeAnimator = nil
            }
        }

        if detentChanged, !reduceMotion {
            let gen = UIImpactFeedbackGenerator(style: .soft)
            gen.prepare()
            gen.impactOccurred()
        }

        currentDetent = detent
        updateAccessibility(for: detent)

        activeAnimator = animator
        animator.startAnimation()
    }

    private func updateAccessibility(for detent: Detent) {
        guard let button = panelView?.handleView.tapButton else { return }
        button.accessibilityLabel = "Scrollback panel"
        switch detent {
        case .peek:
            button.accessibilityValue = "collapsed"
            button.accessibilityHint = "Double tap to expand"
        case .mid:
            button.accessibilityValue = "partially expanded"
            button.accessibilityHint = "Double tap to expand further"
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
}

// MARK: - Data source / delegate

extension ScrollbackPanelController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        store?.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ScrollbackLineCell.reuseID, for: indexPath)
        if let line = store?.line(at: indexPath.item), let typedCell = cell as? ScrollbackLineCell {
            typedCell.configure(attributed: line)
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
