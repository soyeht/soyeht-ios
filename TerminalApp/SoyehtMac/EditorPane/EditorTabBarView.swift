import AppKit

struct EditorTabItem {
    let path: String
    let title: String
    let symbolName: String
    let symbolColor: NSColor
    let isActive: Bool
    let isDirty: Bool
}

@MainActor
final class EditorTabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onReorder: (([String]) -> Void)?

    private enum Metrics {
        static let height: CGFloat = 32
        static let minWidth: CGFloat = 132
        static let maxWidth: CGFloat = 240
        static let dragThreshold: CGFloat = 4
        static let edgeScrollInset: CGFloat = 34
        static let edgeScrollStep: CGFloat = 9
    }

    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class PendingDrag {
        weak var sourceView: EditorTabItemView?
        let path: String
        let startWindowLocation: NSPoint
        let offsetX: CGFloat

        init(sourceView: EditorTabItemView, path: String, startWindowLocation: NSPoint, offsetX: CGFloat) {
            self.sourceView = sourceView
            self.path = path
            self.startWindowLocation = startWindowLocation
            self.offsetX = offsetX
        }
    }

    private final class DragSession {
        weak var sourceView: EditorTabItemView?
        let path: String
        let offsetX: CGFloat
        let ghostView: EditorTabItemView
        var insertionIndex: Int
        var lastWindowLocation: NSPoint

        init(
            sourceView: EditorTabItemView,
            path: String,
            offsetX: CGFloat,
            ghostView: EditorTabItemView,
            insertionIndex: Int,
            lastWindowLocation: NSPoint
        ) {
            self.sourceView = sourceView
            self.path = path
            self.offsetX = offsetX
            self.ghostView = ghostView
            self.insertionIndex = insertionIndex
            self.lastWindowLocation = lastWindowLocation
        }
    }

    private let scrollView = NSScrollView()
    private let documentView = DocumentView()
    private var items: [EditorTabItem] = []
    private var tabViews: [String: EditorTabItemView] = [:]
    private var pendingDrag: PendingDrag?
    private var dragSession: DragSession?
    private var mouseDownEventMonitor: Any?
    private var dragEventMonitor: Any?
    private var autoScrollTimer: Timer?
    private var autoScrollVelocity: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = EditorPaneDesign.chrome.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        documentView.frame = NSRect(x: 0, y: 0, width: 1, height: Metrics.height)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        startMouseDownEventMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        autoScrollTimer?.invalidate()
        if let mouseDownEventMonitor {
            NSEvent.removeMonitor(mouseDownEventMonitor)
        }
        if let dragEventMonitor {
            NSEvent.removeMonitor(dragEventMonitor)
        }
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    func setItems(_ newItems: [EditorTabItem]) {
        removeLingeringGhostViews()

        items = newItems
        let validPaths = Set(newItems.map(\.path))

        for (path, view) in tabViews where !validPaths.contains(path) {
            view.removeFromSuperview()
        }
        tabViews = tabViews.filter { validPaths.contains($0.key) }

        for item in newItems {
            if let view = tabViews[item.path] {
                view.update(item: item)
            } else {
                let view = EditorTabItemView(item: item)
                view.owner = self
                tabViews[item.path] = view
                documentView.addSubview(view)
            }
        }

        applyTheme()
        layoutTabs(animated: false)
        revealActiveTabIfNeeded()
    }

    func applyTheme() {
        layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        documentView.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        tabViews.values.forEach { $0.applyTheme() }
        dragSession?.ghostView.applyTheme()
    }

    fileprivate func tabMouseDown(_ tabView: EditorTabItemView, event: NSEvent, windowLocation: NSPoint? = nil) {
        guard items.count > 0 else { return }
        let location = windowLocation ?? event.locationInWindow
        onSelect?(tabView.item.path)

        let point = documentView.convert(location, from: nil)
        pendingDrag = PendingDrag(
            sourceView: tabView,
            path: tabView.item.path,
            startWindowLocation: location,
            offsetX: point.x - tabView.frame.minX
        )
        startDragEventMonitor()
    }

    fileprivate func tabMouseDragged(_ tabView: EditorTabItemView, event: NSEvent) {
        if let dragSession, dragSession.path == tabView.item.path {
            updateDrag(windowLocation: event.locationInWindow)
            return
        }

        guard pendingDrag?.path == tabView.item.path else { return }
        updatePendingDrag(windowLocation: event.locationInWindow)
    }

    fileprivate func tabMouseUp(_ tabView: EditorTabItemView, event: NSEvent) {
        if let dragSession, dragSession.path == tabView.item.path {
            finishDrag()
        }
        pendingDrag = nil
        stopDragEventMonitor()
        stopAutoScroll()
    }

    fileprivate func closeTab(_ tabView: EditorTabItemView) {
        pendingDrag = nil
        onClose?(tabView.item.path)
    }

    private func startDrag(from pendingDrag: PendingDrag, currentWindowLocation: NSPoint) {
        guard dragSession == nil,
              let sourceView = pendingDrag.sourceView,
              let item = items.first(where: { $0.path == pendingDrag.path }),
              items.count > 1 else { return }

        removeLingeringGhostViews()

        let ghostView = EditorTabItemView(item: item)
        ghostView.owner = self
        ghostView.isGhost = true
        ghostView.frame = sourceView.frame
        ghostView.alphaValue = 0.78
        ghostView.layer?.shadowColor = NSColor.black.cgColor
        ghostView.layer?.shadowOpacity = 0.24
        ghostView.layer?.shadowRadius = 10
        ghostView.layer?.shadowOffset = NSSize(width: 0, height: 4)
        documentView.addSubview(ghostView, positioned: .above, relativeTo: nil)

        sourceView.alphaValue = 0

        let insertionIndex = insertionIndex(for: currentWindowLocation, draggingPath: pendingDrag.path)
        dragSession = DragSession(
            sourceView: sourceView,
            path: pendingDrag.path,
            offsetX: pendingDrag.offsetX,
            ghostView: ghostView,
            insertionIndex: insertionIndex,
            lastWindowLocation: currentWindowLocation
        )
        layoutTabs(animated: true)
        updateDrag(windowLocation: currentWindowLocation)
        startAutoScroll()
    }

    private func updatePendingDrag(windowLocation: NSPoint) {
        guard let pendingDrag else { return }
        let dx = windowLocation.x - pendingDrag.startWindowLocation.x
        let dy = windowLocation.y - pendingDrag.startWindowLocation.y
        guard hypot(dx, dy) >= Metrics.dragThreshold else { return }
        startDrag(from: pendingDrag, currentWindowLocation: windowLocation)
    }

    private func updateDrag(windowLocation: NSPoint) {
        guard let dragSession else { return }
        dragSession.lastWindowLocation = windowLocation

        let contentPoint = documentView.convert(windowLocation, from: nil)
        let width = tabWidth(forPath: dragSession.path)
        let maxX = max(0, documentView.frame.width - width)
        let ghostX = min(max(contentPoint.x - dragSession.offsetX, 0), maxX)
        dragSession.ghostView.frame = NSRect(x: ghostX, y: 0, width: width, height: Metrics.height)

        let newIndex = insertionIndex(for: windowLocation, draggingPath: dragSession.path)
        if newIndex != dragSession.insertionIndex {
            dragSession.insertionIndex = newIndex
            layoutTabs(animated: true)
        }

        updateAutoScrollVelocity(windowLocation: windowLocation)
        performAutoScrollStep(shouldUpdateDrag: false)
    }

    private func finishDrag() {
        guard let dragSession else { return }
        stopDragEventMonitor()
        stopAutoScroll()
        let oldPaths = items.map(\.path)
        var reorderedPaths = oldPaths.filter { $0 != dragSession.path }
        reorderedPaths.insert(dragSession.path, at: min(dragSession.insertionIndex, reorderedPaths.count))

        let reorderedItems = reorderedPaths.compactMap { path in
            items.first { $0.path == path }
        }
        items = reorderedItems

        let ghostView = dragSession.ghostView
        let sourceView = dragSession.sourceView
        self.dragSession = nil
        sourceView?.alphaValue = 1
        ghostView.isGhost = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            ghostView.animator().alphaValue = 0
            layoutTabs(animated: true)
        } completionHandler: {
            ghostView.removeFromSuperview()
        }

        if reorderedPaths != oldPaths {
            onReorder?(reorderedPaths)
        }
    }

    private func removeLingeringGhostViews() {
        for case let tabView as EditorTabItemView in documentView.subviews where tabView.isGhost {
            tabView.removeFromSuperview()
        }
    }

    private func startDragEventMonitor() {
        stopDragEventMonitor()
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self,
                  self.dragSession != nil || self.pendingDrag != nil else { return event }
            switch event.type {
            case .leftMouseDragged:
                guard let windowLocation = self.windowLocation(for: event) else { return event }
                if self.dragSession != nil {
                    self.updateDrag(windowLocation: windowLocation)
                    return nil
                }
                self.updatePendingDrag(windowLocation: windowLocation)
                return nil
            case .leftMouseUp:
                let wasDragging = self.dragSession != nil
                if wasDragging {
                    self.finishDrag()
                }
                self.pendingDrag = nil
                self.stopAutoScroll()
                if !wasDragging {
                    self.stopDragEventMonitor()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func startMouseDownEventMonitor() {
        mouseDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  self.dragSession == nil,
                  self.pendingDrag == nil,
                  let windowLocation = self.windowLocation(for: event) else { return event }

            let localPoint = self.convert(windowLocation, from: nil)
            guard self.bounds.contains(localPoint),
                  let tabView = self.tabView(atWindowLocation: windowLocation) else { return event }

            let pointInTab = tabView.convert(windowLocation, from: nil)
            if tabView.containsCloseButton(point: pointInTab) {
                self.closeTab(tabView)
            } else {
                self.tabMouseDown(tabView, event: event, windowLocation: windowLocation)
            }
            return nil
        }
    }

    private func stopDragEventMonitor() {
        if let dragEventMonitor {
            NSEvent.removeMonitor(dragEventMonitor)
        }
        dragEventMonitor = nil
    }

    private func tabView(atWindowLocation windowLocation: NSPoint) -> EditorTabItemView? {
        let documentPoint = documentView.convert(windowLocation, from: nil)
        return items
            .compactMap { tabViews[$0.path] }
            .first { $0.frame.contains(documentPoint) }
    }

    private func windowLocation(for event: NSEvent) -> NSPoint? {
        if let eventWindow = event.window {
            guard eventWindow === window else { return nil }
            return event.locationInWindow
        }
        guard let window else { return nil }
        return window.convertPoint(fromScreen: NSEvent.mouseLocation)
    }

    private func insertionIndex(for windowLocation: NSPoint, draggingPath: String) -> Int {
        let contentPoint = documentView.convert(windowLocation, from: nil)
        let remaining = items.filter { $0.path != draggingPath }
        var cursor: CGFloat = 0

        for (index, item) in remaining.enumerated() {
            let width = tabWidth(for: item)
            if contentPoint.x < cursor + (width / 2) {
                return index
            }
            cursor += width
        }
        return remaining.count
    }

    private func layoutTabs(animated: Bool) {
        guard !items.isEmpty else {
            documentView.setFrameSize(NSSize(width: max(bounds.width, 1), height: Metrics.height))
            return
        }

        let height = max(bounds.height, Metrics.height)
        let draggedPath = dragSession?.path
        let insertionIndex = dragSession?.insertionIndex ?? 0
        let orderedItems = items.filter { $0.path != draggedPath }
        let draggedWidth = draggedPath.map { tabWidth(forPath: $0) } ?? 0
        let totalWidth = items.reduce(CGFloat(0)) { $0 + tabWidth(for: $1) }
        documentView.setFrameSize(NSSize(width: max(totalWidth, scrollView.contentView.bounds.width, bounds.width), height: height))

        let frameUpdates = tabFrames(
            for: orderedItems,
            draggedPath: draggedPath,
            draggedWidth: draggedWidth,
            insertionIndex: insertionIndex,
            height: height
        )

        let applyFrames = {
            for (path, frame) in frameUpdates {
                guard let view = self.tabViews[path] else { continue }
                if animated, view.window != nil {
                    view.animator().frame = frame
                } else {
                    view.frame = frame
                }
            }
        }

        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                applyFrames()
            }
        } else {
            applyFrames()
        }
    }

    private func revealActiveTabIfNeeded() {
        guard dragSession == nil,
              let activePath = items.first(where: { $0.isActive })?.path else { return }
        revealTabIfNeeded(path: activePath)
    }

    private func revealTabIfNeeded(path: String) {
        guard let tabView = tabViews[path] else { return }
        let clipView = scrollView.contentView
        let visible = clipView.bounds.insetBy(dx: 14, dy: 0)
        guard tabView.frame.minX < visible.minX || tabView.frame.maxX > visible.maxX else { return }

        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        var origin = clipView.bounds.origin
        if tabView.frame.minX < visible.minX {
            origin.x = max(0, tabView.frame.minX - 14)
        } else {
            origin.x = min(maxX, tabView.frame.maxX - clipView.bounds.width + 14)
        }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func tabFrames(
        for orderedItems: [EditorTabItem],
        draggedPath: String?,
        draggedWidth: CGFloat,
        insertionIndex: Int,
        height: CGFloat
    ) -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        var x: CGFloat = 0

        for index in 0...orderedItems.count {
            if draggedPath != nil, index == insertionIndex {
                x += draggedWidth
            }
            guard index < orderedItems.count else { continue }
            let item = orderedItems[index]
            let width = tabWidth(for: item)
            frames[item.path] = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }

        return frames
    }

    private func tabWidth(forPath path: String) -> CGFloat {
        guard let item = items.first(where: { $0.path == path }) else { return Metrics.minWidth }
        return tabWidth(for: item)
    }

    private func tabWidth(for item: EditorTabItem) -> CGFloat {
        let font = EditorTabItemView.titleFont
        let titleWidth = ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        return min(max(titleWidth + 78, Metrics.minWidth), Metrics.maxWidth)
    }

    private func startAutoScroll() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickAutoScroll()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollVelocity = 0
    }

    private func updateAutoScrollVelocity(windowLocation: NSPoint) {
        let localPoint = convert(windowLocation, from: nil)
        if localPoint.x < Metrics.edgeScrollInset {
            autoScrollVelocity = -Metrics.edgeScrollStep
        } else if localPoint.x > bounds.width - Metrics.edgeScrollInset {
            autoScrollVelocity = Metrics.edgeScrollStep
        } else {
            autoScrollVelocity = 0
        }
    }

    private func tickAutoScroll() {
        performAutoScrollStep(shouldUpdateDrag: true)
    }

    private func performAutoScrollStep(shouldUpdateDrag: Bool) {
        guard let dragSession,
              autoScrollVelocity != 0 else { return }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        guard maxX > 0 else { return }

        var origin = clipView.bounds.origin
        let nextX = min(max(origin.x + autoScrollVelocity, 0), maxX)
        guard nextX != origin.x else { return }

        origin.x = nextX
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        if shouldUpdateDrag {
            updateDrag(windowLocation: dragSession.lastWindowLocation)
        }
    }
}

@MainActor
private final class EditorTabItemView: NSView {
    static let titleFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    weak var owner: EditorTabBarView?
    private(set) var item: EditorTabItem
    var isGhost = false {
        didSet {
            closeButton.isHidden = isGhost
            toolTip = isGhost ? nil : item.path
            updateAccessibility()
        }
    }

    private final class PassthroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class PassthroughTextField: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let iconView = PassthroughImageView()
    private let titleLabel = PassthroughTextField(labelWithString: "")
    private let dirtyDot = PassthroughView()
    private let closeButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { applyTheme() }
    }

    override var isFlipped: Bool { true }

    init(item: EditorTabItem) {
        self.item = item
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = Self.titleFont
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        addSubview(dirtyDot)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isBordered = false
        closeButton.image?.isTemplate = true
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.toolTip = "Close"
        addSubview(closeButton)

        setAccessibilityRole(.button)
        iconView.setAccessibilityElement(true)
        titleLabel.setAccessibilityElement(true)
        dirtyDot.setAccessibilityElement(false)
        closeButton.setAccessibilityElement(true)
        update(item: item)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isGhost,
              bounds.contains(point) else { return nil }
        if !closeButton.isHidden {
            let closePoint = closeButton.convert(point, from: self)
            if closeButton.bounds.contains(closePoint) {
                return closeButton.hitTest(closePoint) ?? closeButton
            }
        }
        return self
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 15
        let closeSize: CGFloat = 16
        let dotSize: CGFloat = 6
        let centerY = bounds.midY
        let leftInset: CGFloat = 11
        let rightInset: CGFloat = 9

        iconView.frame = NSRect(
            x: leftInset,
            y: centerY - (iconSize / 2),
            width: iconSize,
            height: iconSize
        )

        closeButton.frame = NSRect(
            x: bounds.width - rightInset - closeSize,
            y: centerY - (closeSize / 2),
            width: closeSize,
            height: closeSize
        )

        let dotX = closeButton.frame.minX - 13
        dirtyDot.frame = NSRect(
            x: dotX,
            y: centerY - (dotSize / 2),
            width: dotSize,
            height: dotSize
        )

        let titleX = iconView.frame.maxX + 8
        let titleRight = item.isDirty ? dirtyDot.frame.minX - 8 : closeButton.frame.minX - 8
        titleLabel.frame = NSRect(
            x: titleX,
            y: centerY - 8,
            width: max(24, titleRight - titleX),
            height: 17
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard !isGhost else { return }
        owner?.tabMouseDown(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isGhost else { return }
        owner?.tabMouseDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isGhost else { return }
        owner?.tabMouseUp(self, event: event)
    }

    func containsCloseButton(point: NSPoint) -> Bool {
        !closeButton.isHidden && closeButton.frame.contains(point)
    }

    func update(item: EditorTabItem) {
        self.item = item
        titleLabel.stringValue = item.title
        toolTip = isGhost ? nil : item.path
        updateAccessibility()

        let image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        iconView.image = image
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = item.symbolColor

        dirtyDot.isHidden = !item.isDirty
        applyTheme()
        needsLayout = true
    }

    private func updateAccessibility() {
        setAccessibilityElement(!isGhost)
        iconView.setAccessibilityElement(!isGhost)
        titleLabel.setAccessibilityElement(!isGhost)
        closeButton.setAccessibilityElement(!isGhost)

        if isGhost {
            setAccessibilityLabel(nil)
            setAccessibilityValue(nil)
        } else {
            setAccessibilityLabel(item.title)
            setAccessibilityValue(item.path)
        }
    }

    func applyTheme() {
        let baseColor: NSColor
        if item.isActive {
            baseColor = EditorPaneDesign.surface
        } else if isHovered && !isGhost {
            baseColor = EditorPaneDesign.surfaceRaised
        } else {
            baseColor = EditorPaneDesign.chrome
        }

        layer?.backgroundColor = baseColor.cgColor
        layer?.borderWidth = item.isActive ? 0 : 0.5
        layer?.borderColor = EditorPaneDesign.border.cgColor
        titleLabel.textColor = item.isActive ? EditorPaneDesign.text : EditorPaneDesign.muted
        iconView.contentTintColor = item.symbolColor
        dirtyDot.layer?.backgroundColor = EditorPaneDesign.orange.cgColor
        closeButton.contentTintColor = (item.isActive || isHovered) ? EditorPaneDesign.text : EditorPaneDesign.muted
    }

    @objc private func closeTapped() {
        owner?.closeTab(self)
    }
}
