import AppKit

/// Single source of truth for forcing a specific `NSCursor` over a region of
/// the UI. AppKit picks the deepest view's cursor rect at the mouse position,
/// so any chrome view that contains text-like children (NSTextField,
/// NSTextView, fields with selectable text) leaks the I-beam unless something
/// further down the responder chain claims arrow.
///
/// The proven-working pattern combines three mechanisms:
/// 1. `resetCursorRects()` adds a cursor rect (the conventional path).
/// 2. A `.cursorUpdate` tracking area fires `cursorUpdate(with:)` when the
///    pointer crosses our bounds (handles cases where the rect path loses to
///    a deeper child).
/// 3. `cursorUpdate(with:)` force-sets the cursor.
///
/// Use `MacCursor.ChromeView` as a base class for chrome containers (root
/// views of panes, toolbars, headers, agent picker rows) and `MacCursor.Label`
/// for any NSTextField that sits inside a clickable parent and would
/// otherwise contribute its default cursor to the resolution.
enum MacCursor {

    /// Drop-in base class: every NSView used as chrome should inherit from
    /// this instead of NSView. Defaults to `.arrow`; pass `.pointingHand` for
    /// clickable rows.
    class ChromeView: NSView {
        let cursor: NSCursor
        private var cursorTracking: NSTrackingArea?

        init(cursor: NSCursor = .arrow) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        override init(frame frameRect: NSRect) {
            self.cursor = .arrow
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            cursorTracking = area
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }
    }


    /// Convenience for views that can't inherit from `ChromeView` because
    /// they already have a different AppKit parent class (NSButton,
    /// NSRulerView, NSTableRowView, etc.). Call from `resetCursorRects()`:
    ///
    ///     override func resetCursorRects() {
    ///         MacCursor.claim(.arrow, on: self)
    ///     }
    ///
    /// This is the only sanctioned form of inline cursor handling outside
    /// `ChromeView`/`Label`. The audit walker treats AppKit subclasses as
    /// safe so they don't appear in the leak report, but routing through
    /// this helper keeps the policy in one file.
    static func claim(_ cursor: NSCursor, on view: NSView) {
        view.addCursorRect(view.bounds, cursor: cursor)
    }

    /// DEBUG-only audit. Walks the hierarchy and reports custom NSView
    /// subclasses that aren't `ChromeView` and aren't in the AppKit safe-list.
    /// Wire into `AppDelegate.applicationDidFinishLaunching(_:)` under
    /// `#if DEBUG` to catch regressions without per-file `#if` guards.
    static func auditHierarchy(_ root: NSView, log: (String) -> Void = { Swift.print("[MacCursor]", $0) }) {
        var leaks: [String] = []
        walk(root, depth: 0, leaks: &leaks)
        if leaks.isEmpty {
            log("audit OK — no chrome cursor leaks found under \(type(of: root))")
        } else {
            log("audit found \(leaks.count) potential cursor leak(s):")
            for line in leaks { log("  - " + line) }
        }
    }

    /// AppKit classes whose default cursor behavior is correct and need no
    /// inheritance from `ChromeView`. Custom subclasses still get audited
    /// unless they inherit from `ChromeView`.
    private static let safeClasses: Set<String> = [
        "NSView", "NSStackView", "NSScrollView", "NSClipView", "NSImageView",
        "NSButton", "NSPopUpButton", "NSSegmentedControl", "NSSlider",
        "NSBox", "NSSplitView", "NSVisualEffectView", "NSScroller",
        "NSProgressIndicator", "NSPathControl", "NSTabView", "NSTabViewItem",
        "NSRulerView", "NSTextField", "NSSearchField", "NSSecureTextField",
        "NSTextView", "NSTokenField", "NSDatePicker", "NSColorWell",
        "NSOutlineView", "NSTableView", "NSTableRowView", "NSTableCellView",
        "NSTableHeaderView", "_NSKeyboardFocusClipView",
    ]

    private static func walk(_ view: NSView, depth: Int, leaks: inout [String]) {
        let cls = String(describing: type(of: view))
        let isChrome = view is ChromeView
        let isSafe = safeClasses.contains(cls)
        // A custom NSView subclass that isn't ChromeView and isn't on the
        // safe list is a candidate leak. AppKit classes (NSButton, NSImageView,
        // etc.) handle cursor themselves so they're allowed unconditionally.
        if !isChrome && !isSafe && cls.hasPrefix("NS") == false {
            leaks.append("\(cls) (depth \(depth)) — consider MacCursor.ChromeView")
        }
        for sub in view.subviews { walk(sub, depth: depth + 1, leaks: &leaks) }
    }

    /// Text label for chrome. NSView-based (NOT NSTextField) so AppKit
    /// doesn't activate `TUINSCursorUIController` / `CursorUIViewService` —
    /// macOS's text-input cursor service that overlays I-beam on top of any
    /// cursor we set whenever an NSTextField exists in the window hierarchy.
    ///
    /// API mirrors NSTextField's basic surface (`stringValue`, `font`,
    /// `textColor`) so it's a drop-in replacement at call sites that don't
    /// rely on selection, editing, or NSCell-specific features.
    ///
    /// Set `passClicksThrough = true` when the label sits inside a clickable
    /// parent so the click goes to the parent rather than being swallowed.
    final class Label: ChromeView {
        private let passClicksThrough: Bool
        private var attributedString = NSAttributedString()

        var stringValue: String = "" {
            didSet { if oldValue != stringValue { rebuild() } }
        }
        var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize) {
            didSet { rebuild() }
        }
        var textColor: NSColor = .labelColor {
            didSet { rebuild() }
        }

        init(text: String = "", cursor: NSCursor = .arrow, passClicksThrough: Bool = false) {
            self.passClicksThrough = passClicksThrough
            super.init(cursor: cursor)
            self.stringValue = text
            rebuild()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        private func rebuild() {
            attributedString = NSAttributedString(string: stringValue, attributes: [
                .font: font,
                .foregroundColor: textColor,
            ])
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }

        override func draw(_ dirtyRect: NSRect) {
            let size = attributedString.size()
            let y = (bounds.height - size.height) / 2
            attributedString.draw(at: NSPoint(x: 0, y: y))
        }

        override var intrinsicContentSize: NSSize { attributedString.size() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            passClicksThrough ? nil : super.hitTest(point)
        }
    }
}
