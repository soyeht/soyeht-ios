import AppKit

/// Overlay that renders neumorphic INNER shadows — the pressed/inset "well"
/// reading for content carved into the surface (the generator's `inset`
/// box-shadow), e.g. the terminal screen sunk into the canvas.
///
/// CALayer has no native inner shadow. The trick: each shape is a RING
/// (huge outer rect + the rounded bounds, even-odd) whose fill lies outside
/// the view's rounded clip — so the fill is invisible and only its shadow
/// falls inward across the edge. Non-interactive; place it above the content
/// it "presses in".
final class MacInnerWellShadowView: NSView {
    private let darkRing = CAShapeLayer()
    private let lightRing = CAShapeLayer()
    /// The lip rides its own ring so it can be hidden on the themes that
    /// state none, and so it sits behind the other two rather than over them.
    private let lipRing = CAShapeLayer()
    private var radius: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // Stacking order is the whole design. Each ring surrounds the hole on
        // all four sides, so its blur bleeds onto the two sides its offset
        // moves it away from: the rim lightens the top-left as well as the
        // bottom-right, and whichever ring is in front wins there. CSS lists
        // the well's shadows dark-first and the first box-shadow in a list is
        // the frontmost, so the dark side belongs ON TOP of the rim. Added
        // back to front here, since a later sublayer is nearer the viewer.
        // The other way round the rim's bleed lifted the top-left from L*
        // 12.9 to 18.9 against a well of 18.9 — the recess had no dark edge
        // at all, which is why a pressed tab read as a flat darker pill.
        for ring in [lipRing, lightRing, darkRing] {
            ring.fillRule = .evenOdd
            ring.fillColor = NSColor.black.cgColor
            layer?.addSublayer(ring)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ring's edge is held `seamGuard` outside the clip, which shifts
    /// every shadow it casts that far back out. Callers state the offset the
    /// design states; the guard is this view's own business and it pays for
    /// it here. Left unpaid, a stated offset of 3 landed as 2 — a third of
    /// the recess gone before the blur is applied.
    private func guarded(_ spec: MacSurface.Shadow) -> MacSurface.Shadow {
        var out = spec
        out.offset = CGSize(
            width: spec.offset.width + seamGuard * (spec.offset.width < 0 ? -1 : 1),
            height: spec.offset.height + seamGuard * (spec.offset.height < 0 ? -1 : 1)
        )
        return out
    }

    /// The cavity's inner edge must NOT land on the clip: they would be the
    /// same curve, both antialiased, and the boundary pixel would take
    /// roughly half the clip's coverage of a black fill — a dark hairline
    /// tracing the pill, which reads as a stroke rather than a recess.
    private let seamGuard: CGFloat = 1

    func applyStyle(
        cornerRadius: CGFloat,
        dark: MacSurface.Shadow,
        light: MacSurface.Shadow,
        lip: MacSurface.Shadow? = nil
    ) {
        radius = cornerRadius
        layer?.cornerRadius = cornerRadius
        for (ring, spec) in [(darkRing, guarded(dark)), (lightRing, guarded(light))] {
            ring.shadowColor = spec.color.cgColor
            ring.shadowOpacity = spec.opacity
            ring.shadowOffset = spec.offset
            ring.shadowRadius = spec.radius
        }
        lipRing.isHidden = lip == nil
        if let lip = lip.map(guarded) {
            lipRing.shadowColor = lip.color.cgColor
            lipRing.shadowOpacity = lip.opacity
            lipRing.shadowOffset = lip.offset
            lipRing.shadowRadius = lip.radius
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The cavity is an opaque ring clipped to the rounded bounds, so only
        // the shadow it throws inward survives. Holding its edge `seamGuard`
        // outside keeps the fill wholly beyond the clip; `guarded(_:)` pays
        // the offset back.
        func ring(outsetBy outset: CGFloat) -> CGPath {
            let inner = bounds.insetBy(dx: -outset, dy: -outset)
            let path = CGMutablePath()
            path.addRect(inner.insetBy(dx: -80, dy: -80))
            path.addPath(CGPath(
                roundedRect: inner,
                cornerWidth: min(radius + outset, inner.width / 2),
                cornerHeight: min(radius + outset, inner.height / 2),
                transform: nil
            ))
            return path
        }
        let ringPath = ring(outsetBy: seamGuard)
        for layer in [darkRing, lightRing] {
            layer.frame = bounds
            layer.path = ringPath
        }
        lipRing.frame = bounds
        lipRing.path = ringPath
        CATransaction.commit()
    }
}

/// An NSView that renders a rounded surface with any number of soft shadows.
///
/// CALayer supports exactly one shadow, so each `MacSurface.Shadow` spec gets
/// its own sublayer stacked behind the fill — this is what makes neumorphism's
/// paired light/dark shadows possible in AppKit. Owners call `applyStyle` from
/// their `applyTheme()` so theme and design-style changes restyle live.
final class MacStyledSurfaceView: NSView {
    /// When true the view is a cosmetic backdrop (shadow/fill only) and never
    /// intercepts clicks — the control it decorates handles them.
    var passesThroughHits = false

    private var shadowLayers: [CALayer] = []
    private let surfaceLayer = CALayer()

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThroughHits ? nil : super.hitTest(point)
    }

    private var fillColor: NSColor = .clear
    private var radius: CGFloat = 0
    private var borderColor: NSColor?
    private var borderWidth: CGFloat = 0
    private var shadowSpecs: [MacSurface.Shadow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(surfaceLayer)
    }

    func applyStyle(
        fill: NSColor,
        cornerRadius: CGFloat,
        border: NSColor? = nil,
        borderWidth: CGFloat = 0,
        shadows: [MacSurface.Shadow] = []
    ) {
        fillColor = fill
        radius = cornerRadius
        borderColor = border
        self.borderWidth = borderWidth
        shadowSpecs = shadows
        rebuildLayers()
        needsLayout = true
    }

    private func rebuildLayers() {
        shadowLayers.forEach { $0.removeFromSuperlayer() }
        surfaceLayer.removeFromSuperlayer()

        shadowLayers = shadowSpecs.map { spec in
            let shadowLayer = CALayer()
            shadowLayer.masksToBounds = false
            spec.apply(to: shadowLayer)
            return shadowLayer
        }
        for (index, shadowLayer) in shadowLayers.enumerated() {
            layer?.insertSublayer(shadowLayer, at: UInt32(index))
        }
        // Surface sits above its shadows but below any subview layers.
        layer?.insertSublayer(surfaceLayer, at: UInt32(shadowLayers.count))

        // Flat fill. This layer used to be a CAGradientLayer that could take
        // a 145-degree pair; the surfaces it painted are one colour in the
        // reviewed design, and no caller passed a pair any more.
        surfaceLayer.backgroundColor = fillColor.cgColor
        surfaceLayer.cornerRadius = radius
        surfaceLayer.borderColor = borderColor?.cgColor
        surfaceLayer.borderWidth = borderWidth
        for shadowLayer in shadowLayers {
            shadowLayer.backgroundColor = fillColor.cgColor
            shadowLayer.cornerRadius = radius
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = bounds
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: min(radius, bounds.width / 2),
            cornerHeight: min(radius, bounds.height / 2),
            transform: nil
        )
        for shadowLayer in shadowLayers {
            shadowLayer.frame = bounds
            shadowLayer.shadowPath = path
        }
        CATransaction.commit()
    }
}
