import AppKit
import SwiftTerm

/// Single source of truth for "attach the shell's scrollbar pill to any
/// NSScrollView" so every special pane (editor, git, future panes) uses
/// the exact same `TerminalScrollIndicatorView` that the terminal/shell
/// already renders. New screens get the golden scroll with one call:
///
///     let scroll = NSScrollView()
///     container.addSubview(scroll)
///     // ... pin scroll edges to container ...
///     MacScroll.attachVerticalIndicator(to: scroll)
///
/// The `TerminalScrollIndicatorView` itself lives in SwiftTerm (the shell
/// already uses it). This file owns *how* every NSScrollView in the app
/// adopts that same indicator — so the shell never has to change but the
/// rest of the app catches up.
///
/// Design notes (carefully addressing previous failed integrations in the
/// editor pane that ended up reverted in commit `a72f7a0`):
///
/// 1. The indicator is added as a **sibling of the scroll view** (a child
///    of the scroll view's `superview`), never as a subview of the scroll
///    view itself. Subviews of NSScrollView get reshuffled by AppKit's
///    `tile()` whenever ruler/clip metrics change; siblings don't.
/// 2. Positioning uses Auto Layout pinned to the scroll view's edges, not
///    `addFloatingSubview(_:for:)` (that path hung the main thread when
///    layer-backed). Auto Layout is the path the shell itself uses.
/// 3. Position math runs off the clip view's `boundsDidChange`
///    notification, exactly as the shell does (no display-link, no
///    polling).
/// 4. The scroll view's `superview` must already exist when this is
///    called — pin the scroll's edges to its container first, then call.
enum MacScroll {

    /// Width matches the SwiftTerm shell pill (`scrollerVisualWidth`).
    /// Keep in sync with `MacTerminalView.scrollerVisualWidth` if that
    /// value ever changes upstream — the visual contract is "same width
    /// as the shell".
    static let indicatorWidth: CGFloat = 15

    /// Attaches the shell's pill to the scroll view's superview. Wires up
    /// the **vertical** indicator by default, and a horizontal indicator
    /// at the bottom edge when the document overflows horizontally. The
    /// binding is idempotent — calling this twice on the same scroll
    /// view is safe and returns the existing binding's vertical indicator.
    @discardableResult
    @MainActor
    static func attachVerticalIndicator(to scrollView: NSScrollView) -> TerminalScrollIndicatorView? {
        guard let host = scrollView.superview else {
            assertionFailure("MacScroll.attachVerticalIndicator: scrollView must be in a superview before attach")
            return nil
        }
        if let existing = scrollView.macScrollBinding?.verticalIndicator {
            return existing
        }

        let vertical = TerminalScrollIndicatorView(frame: .zero)
        vertical.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(vertical, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            vertical.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            vertical.topAnchor.constraint(equalTo: scrollView.topAnchor),
            vertical.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            vertical.widthAnchor.constraint(equalToConstant: indicatorWidth),
        ])

        let horizontal = HorizontalScrollIndicatorView(frame: .zero)
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(horizontal, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            horizontal.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            horizontal.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            horizontal.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            horizontal.heightAnchor.constraint(equalToConstant: indicatorWidth),
        ])

        // Hide the system scrollers and let the pills carry the visual,
        // matching the shell's setup. Horizontal scrolling still works
        // via trackpad/wheel.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let binding = ScrollIndicatorBinding(
            scrollView: scrollView,
            verticalIndicator: vertical,
            horizontalIndicator: horizontal
        )
        scrollView.macScrollBinding = binding
        binding.refresh()
        return vertical
    }
}

/// Horizontal twin of `TerminalScrollIndicatorView` from SwiftTerm. The
/// shell only needs vertical (terminals wrap, no horizontal scrollback),
/// so this class lives here, in soyeht-mac, where the editor and git
/// diff panes can overflow horizontally and need a matching pill. Pixel
/// geometry mirrors the vertical pill: 3pt thick, rounded, same alphas.
final class HorizontalScrollIndicatorView: NSView {
    var onScrollToPosition: ((Double) -> Void)?

    var isScrollable = false {
        didSet {
            isHidden = !isScrollable
            alphaValue = isScrollable ? 1 : 0
            needsDisplay = true
        }
    }

    /// 0 = left edge of content visible, 1 = right edge.
    var position: Double = 0 { didSet { needsDisplay = true } }
    var thumbProportion: CGFloat = 1 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        alphaValue = 0
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isScrollable else { return }
        let track = trackRect
        let thumb = thumbRect(in: track)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        NSColor.labelColor.withAlphaComponent(0.44).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
    }

    override func mouseDown(with event: NSEvent) { updateScrollPosition(from: event) }
    override func mouseDragged(with event: NSEvent) { updateScrollPosition(from: event) }

    private var trackRect: NSRect {
        let height: CGFloat = 3
        let horizontalInset: CGFloat = 6
        // Pin to bottom of bounds; 4pt from the very bottom edge.
        return NSRect(
            x: horizontalInset,
            y: 4,
            width: max(0, bounds.width - horizontalInset * 2),
            height: height
        )
    }

    private func thumbRect(in track: NSRect) -> NSRect {
        let proportion = min(max(thumbProportion, 0.04), 1)
        let thumbWidth = min(track.width, max(28, track.width * proportion))
        let travel = max(0, track.width - thumbWidth)
        let clampedPosition = min(max(position, 0), 1)
        let x = track.minX + travel * CGFloat(clampedPosition)
        return NSRect(x: x, y: track.minY, width: thumbWidth, height: track.height)
    }

    private func updateScrollPosition(from event: NSEvent) {
        let track = trackRect
        let thumb = thumbRect(in: track)
        let travel = max(0, track.width - thumb.width)
        guard travel > 0 else { onScrollToPosition?(0); return }
        let location = convert(event.locationInWindow, from: nil)
        let centeredThumbX = location.x - thumb.width / 2
        let clampedThumbX = min(max(centeredThumbX, track.minX), track.maxX - thumb.width)
        let newPosition = Double((clampedThumbX - track.minX) / travel)
        onScrollToPosition?(min(max(newPosition, 0), 1))
    }
}

/// Holds the wiring between an `NSScrollView` and its overlay pill. Lives
/// as an associated object on the scroll view so cleanup is automatic:
/// when the scroll view deallocates, this binding deallocates with it,
/// `deinit` removes the notification observer, and the indicator (a
/// subview of the scroll's superview) gets torn down when its parent
/// goes away. No explicit cleanup needed at call sites.
@MainActor
private final class ScrollIndicatorBinding {
    weak var scrollView: NSScrollView?
    let verticalIndicator: TerminalScrollIndicatorView
    let horizontalIndicator: HorizontalScrollIndicatorView
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?

    init(scrollView: NSScrollView,
         verticalIndicator: TerminalScrollIndicatorView,
         horizontalIndicator: HorizontalScrollIndicatorView) {
        self.scrollView = scrollView
        self.verticalIndicator = verticalIndicator
        self.horizontalIndicator = horizontalIndicator
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Also refresh when the document grows/shrinks (table reloads,
        // text edits, sidebar items appear/disappear). Without this, a
        // table that reloads with new row counts can leave stale pill
        // state because the clipView's bounds didn't change.
        if let doc = scrollView.documentView {
            doc.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: doc,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        verticalIndicator.onScrollToPosition = { [weak self] position in
            MainActor.assumeIsolated { self?.scrollVertical(toIndicatorPosition: position) }
        }
        horizontalIndicator.onScrollToPosition = { [weak self] position in
            MainActor.assumeIsolated { self?.scrollHorizontal(toIndicatorPosition: position) }
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    func refresh() {
        guard let scrollView,
              let doc = scrollView.documentView else {
            verticalIndicator.isScrollable = false
            horizontalIndicator.isScrollable = false
            return
        }
        let clipBounds = scrollView.contentView.bounds
        let visibleHeight = clipBounds.height
        let visibleWidth = clipBounds.width

        // Tables (and outline views) need special handling: their
        // documentView frame can be sized to fill the clip view even
        // when only a few rows have data, and their column may be
        // wider than the clip view even when no real horizontal
        // scrolling is desired. Compute true content height from
        // `rect(ofRow:)` and never report horizontal overflow.
        let totalHeight: CGFloat
        let totalWidth: CGFloat
        if let table = doc as? NSTableView {
            let headerHeight = table.headerView?.frame.height ?? 0
            if table.numberOfRows > 0 {
                let lastRect = table.rect(ofRow: table.numberOfRows - 1)
                totalHeight = lastRect.maxY + headerHeight
            } else {
                totalHeight = headerHeight
            }
            // Sidebars don't scroll horizontally; pin to visible width.
            totalWidth = visibleWidth
        } else {
            totalHeight = doc.bounds.height
            totalWidth = doc.bounds.width
        }

        let vOverflow = totalHeight - visibleHeight
        let canScrollV = vOverflow > 8
        verticalIndicator.isScrollable = canScrollV
        if canScrollV {
            let maxScrollV = max(1, vOverflow)
            // documentView is flipped (NSTextView/NSTableView), so
            // clipView.bounds.origin.y grows from 0 at top → maxScroll
            // at bottom, matching the pill's top-to-bottom convention.
            verticalIndicator.position = Double(clipBounds.origin.y / maxScrollV)
            verticalIndicator.thumbProportion = max(0.05, visibleHeight / totalHeight)
        }

        // Horizontal: editor body word-wraps (no horizontal overflow),
        // git diff doesn't (long hunk lines overflow), so this only
        // renders when actually needed. Tables skip this entirely.
        let hOverflow = totalWidth - visibleWidth
        let canScrollH = hOverflow > 8
        horizontalIndicator.isScrollable = canScrollH
        if canScrollH {
            let maxScrollH = max(1, hOverflow)
            horizontalIndicator.position = Double(clipBounds.origin.x / maxScrollH)
            horizontalIndicator.thumbProportion = max(0.05, visibleWidth / totalWidth)
        }
    }

    func scrollVertical(toIndicatorPosition position: Double) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let visibleHeight = scrollView.contentView.bounds.height
        let totalHeight = doc.bounds.height
        guard totalHeight > visibleHeight else { return }
        let clipY = position * Double(totalHeight - visibleHeight)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: clipY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollHorizontal(toIndicatorPosition position: Double) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let visibleWidth = scrollView.contentView.bounds.width
        let totalWidth = doc.bounds.width
        guard totalWidth > visibleWidth else { return }
        let clipX = position * Double(totalWidth - visibleWidth)
        scrollView.contentView.scroll(to: NSPoint(x: clipX, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - Associated-object plumbing

private var macScrollBindingKey: UInt8 = 0

private extension NSScrollView {
    @MainActor
    var macScrollBinding: ScrollIndicatorBinding? {
        get { objc_getAssociatedObject(self, &macScrollBindingKey) as? ScrollIndicatorBinding }
        set { objc_setAssociatedObject(self, &macScrollBindingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
