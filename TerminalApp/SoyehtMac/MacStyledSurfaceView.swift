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
    private var radius: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for ring in [darkRing, lightRing] {
            ring.fillRule = .evenOdd
            ring.fillColor = NSColor.black.cgColor
            layer?.addSublayer(ring)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyStyle(cornerRadius: CGFloat, dark: MacSurface.Shadow, light: MacSurface.Shadow) {
        radius = cornerRadius
        layer?.cornerRadius = cornerRadius
        for (ring, spec) in [(darkRing, dark), (lightRing, light)] {
            ring.shadowColor = spec.color.cgColor
            ring.shadowOpacity = spec.opacity
            ring.shadowOffset = spec.offset
            ring.shadowRadius = spec.radius
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ringPath = CGMutablePath()
        ringPath.addRect(bounds.insetBy(dx: -80, dy: -80))
        ringPath.addPath(CGPath(
            roundedRect: bounds,
            cornerWidth: min(radius, bounds.width / 2),
            cornerHeight: min(radius, bounds.height / 2),
            transform: nil
        ))
        for ring in [darkRing, lightRing] {
            ring.frame = bounds
            ring.path = ringPath
        }
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
    private let surfaceLayer = CAGradientLayer()

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThroughHits ? nil : super.hitTest(point)
    }

    private var fillColor: NSColor = .clear
    private var gradientColors: (start: NSColor, end: NSColor)?
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
        gradient: (start: NSColor, end: NSColor)? = nil,
        cornerRadius: CGFloat,
        border: NSColor? = nil,
        borderWidth: CGFloat = 0,
        shadows: [MacSurface.Shadow] = []
    ) {
        fillColor = fill
        gradientColors = gradient
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

        // The generator-style diagonal surface gradient (CSS 145deg,
        // top-left -> bottom-right in unflipped layer coordinates). Flat
        // fill when no gradient is requested.
        if let gradientColors {
            surfaceLayer.backgroundColor = nil
            surfaceLayer.colors = [gradientColors.start.cgColor, gradientColors.end.cgColor]
            surfaceLayer.startPoint = CGPoint(x: 0.09, y: 0.91)
            surfaceLayer.endPoint = CGPoint(x: 0.91, y: 0.09)
        } else {
            surfaceLayer.colors = nil
            surfaceLayer.backgroundColor = fillColor.cgColor
        }
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
