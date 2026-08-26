import AppKit
import Testing
@testable import SoyehtMacDomain

/// The neumorphic shadow code, tested by RENDERING it and measuring pixels.
///
/// Three defects shipped here and no test caught any of them, because none of
/// this had a test at all: a blur applied at twice its intended width, a ring
/// stacking order that painted the lit side over the shaded one and left a
/// pressed control with no dark edge whatsoever, and a geometry guard that was
/// never paid back so a stated offset of 3 landed as 2. Every one is invisible
/// to a test that reads the specs back — the numbers were right, what they
/// produced was not. So these render.
@Suite("Neumorphic shadow rendering")
struct NeoShadowRenderingTests {

    // MARK: - Pixels

    /// Renders a view offscreen in sRGB and hands back a lightness probe
    /// addressed in POINTS from the top-left.
    ///
    /// Two conversions, both of which produce nonsense numbers when skipped
    /// and neither of which announces itself:
    ///
    /// `cacheDisplay` draws in the display's own colour space, so without the
    /// sRGB conversion every value measured is a colour nobody set — caught
    /// against the real app, where a canvas of `#223F48` came back as
    /// `(26,48,56)`.
    ///
    /// And the bitmap is backed at the screen's scale, so on a Retina display
    /// it holds two pixels per point. Probing it with point coordinates reads
    /// a different part of the image entirely: the first version of these
    /// tests failed on a surface asked for NO shadows, because the row it
    /// called "below the pill" was inside it.
    static func lightnessProbe(of view: NSView) -> (Int, Int) -> Double {
        view.layoutSubtreeIfNeeded()
        let raw = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        raw.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: raw)
        let rep = raw.converting(to: .sRGB, renderingIntent: .default) ?? raw
        let scale = Double(rep.pixelsWide) / Double(view.bounds.width)
        return { pointX, pointY in
            let x = Int((Double(pointX) + 0.5) * scale)
            let y = Int((Double(pointY) + 0.5) * scale)
            guard let colour = rep.colorAt(x: x, y: y) else { return .nan }
            func linear(_ channel: CGFloat) -> Double {
                let c = Double(channel)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(colour.redComponent)
                + 0.7152 * linear(colour.greenComponent)
                + 0.0722 * linear(colour.blueComponent)
            return luminance > 0.008856
                ? 116 * pow(luminance, 1.0 / 3.0) - 16
                : 903.3 * luminance
        }
    }

    static func colour(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1)
    }

    // Deep Harbor, as the preset states it.
    static let canvas = colour("#223F48")
    static let chrome = colour("#2B4851")
    static let well = colour("#13313A")
    static let shadowDark = colour("#112F37")
    static let shadowLight = colour("#3B5861")
    static let wellShadow = colour("#001E26")
    static let wellRim = colour("#304D56")
    static let wellLip = colour("#00151B")

    // MARK: - The blur conversion

    /// A CSS blur of B and a CALayer `shadowRadius` of B are not the same
    /// shadow: CSS blurs with a standard deviation of B/2, CALayer with B.
    /// Every spec here was written by reading a blur off the design and
    /// assigning it to `radius`, so all of them rendered twice as soft.
    @Test func aStatedBlurBecomesHalfAsMuchLayerRadius() {
        let spec = MacSurface.Shadow.neo(
            color: .black, offset: CGSize(width: 4, height: -4), blur: 8)
        #expect(spec.radius == 4)
        #expect(spec.offset == CGSize(width: 4, height: -4))
        #expect(spec.opacity == 1)
    }

    // MARK: - The recess

    /// A pressed control has a DARK top-left edge. It is the whole of what
    /// makes it look pressed.
    ///
    /// Each ring surrounds the hole on all four sides, so its blur bleeds onto
    /// the two sides its offset moves it away from, and whichever ring is in
    /// front wins there. With the rim in front its bleed lifted the top-left
    /// to the well's own lightness and the recess simply had no dark edge —
    /// the pressed workspace tab was a flat, slightly darker pill.
    @Test func theRecessIsDarkAtTheTopLeftAndLitAtTheBottomRight() {
        let size = NSSize(width: 150, height: 33)
        let radius = min(size.height / 2, 18)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.well.cgColor

        let cavity = MacInnerWellShadowView(frame: NSRect(origin: .zero, size: size))
        cavity.applyStyle(
            cornerRadius: radius,
            dark: .neo(color: Self.wellShadow, offset: CGSize(width: 3, height: -3), blur: 6),
            light: .neo(color: Self.wellRim, offset: CGSize(width: -3, height: 3), blur: 7),
            lip: .neo(color: Self.wellLip, offset: CGSize(width: 1, height: -1), blur: 0))
        host.addSubview(cavity)

        let lightness = Self.lightnessProbe(of: host)
        let middle = lightness(75, 16)

        // Rows are top-down in the bitmap, so y = 1 is the top edge.
        let topEdge = lightness(75, 0)
        let leftEdge = lightness(0, 16)
        let bottomEdge = lightness(75, Int(size.height) - 2)
        let rightEdge = lightness(Int(size.width) - 2, 16)

        // 8 rather than a token gap. The recess sits at L* 8.1 against a
        // well of 18.5 when the geometry is right; leaving the seam guard
        // unpaid — the ring is held a point outside the clip, which shifts
        // every shadow it casts that far back out — lands it at 12.8, still
        // "darker" but a third of the depth gone. A loose threshold would
        // wave that through.
        #expect(topEdge < middle - 8,
                "top edge \(topEdge) is not dark enough against the well \(middle)")
        #expect(leftEdge < middle - 8,
                "left edge \(leftEdge) is not dark enough against the well \(middle)")
        #expect(bottomEdge > middle + 2,
                "bottom edge \(bottomEdge) is not lighter than the well \(middle)")
        #expect(rightEdge > middle + 2,
                "right edge \(rightEdge) is not lighter than the well \(middle)")
    }

    /// The dark ring is painted IN FRONT of the rim.
    ///
    /// Each ring surrounds the hole on all four sides, so its blur bleeds onto
    /// the two sides its offset moves it away from, and whichever is in front
    /// wins there. CSS lists the well's shadows dark-first and the first
    /// box-shadow in a list is the frontmost.
    ///
    /// At the design's own numbers the two orders differ by about 1 L*, which
    /// no honest threshold separates — the order mattered when the blur was
    /// also doubled, and those two together erased the dark edge completely.
    /// So this asks the question with a rim loud enough to answer it: white,
    /// far too soft, aimed away from the top-left. In front it floods the
    /// whole cavity; behind it changes the top-left barely at all.
    @Test func theDarkRingIsPaintedInFrontOfTheRim() {
        let size = NSSize(width: 150, height: 33)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.well.cgColor
        let cavity = MacInnerWellShadowView(frame: NSRect(origin: .zero, size: size))
        cavity.applyStyle(
            cornerRadius: 16.5,
            dark: .neo(color: .black, offset: CGSize(width: 3, height: -3), blur: 6),
            light: .neo(color: .white, offset: CGSize(width: -3, height: 3), blur: 40))
        host.addSubview(cavity)
        let lightness = Self.lightnessProbe(of: host)
        // Behind the dark ring this reads about 23; in front of it, 55.
        #expect(lightness(75, 0) < 35,
                "a shouting rim reached the top-left at \(lightness(75, 0)) — it is in front")
    }

    /// The dark side survives the rim at the design's real numbers too.
    @Test func theRimDoesNotEraseTheDarkEdge() {
        let size = NSSize(width: 150, height: 33)
        func topEdgeLightness(withRim rim: Bool) -> Double {
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            host.layer?.backgroundColor = Self.well.cgColor
            let cavity = MacInnerWellShadowView(frame: NSRect(origin: .zero, size: size))
            cavity.applyStyle(
                cornerRadius: min(size.height / 2, 18),
                dark: .neo(color: Self.wellShadow, offset: CGSize(width: 3, height: -3), blur: 6),
                light: rim
                    ? .neo(color: Self.wellRim, offset: CGSize(width: -3, height: 3), blur: 7)
                    : .neo(color: .clear, opacity: 0, offset: .zero, blur: 0))
            host.addSubview(cavity)
            return Self.lightnessProbe(of: host)(75, 0)
        }
        let withRim = topEdgeLightness(withRim: true)
        let withoutRim = topEdgeLightness(withRim: false)
        #expect(abs(withRim - withoutRim) < 3,
                "the rim moved the dark edge from \(withoutRim) to \(withRim)")
    }

    /// A theme that states no lip renders without one, and the two rings that
    /// remain still carve the recess.
    @Test func aWellWithoutALipStillReadsAsPressed() {
        let size = NSSize(width: 150, height: 33)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.well.cgColor
        let cavity = MacInnerWellShadowView(frame: NSRect(origin: .zero, size: size))
        cavity.applyStyle(
            cornerRadius: min(size.height / 2, 18),
            dark: .neo(color: Self.wellShadow, offset: CGSize(width: 3, height: -3), blur: 6),
            light: .neo(color: Self.wellRim, offset: CGSize(width: -3, height: 3), blur: 7))
        host.addSubview(cavity)
        let lightness = Self.lightnessProbe(of: host)
        // Shallower than the three-ring well above — the lip contributes
        // about 2 L* of its own — so the floor is lower, not absent.
        #expect(lightness(75, 0) < lightness(75, 16) - 6)
    }

    // MARK: - The raised surface

    /// A raised pill throws its shadow down-right and its bloom up-left, and
    /// both reach about as far as the design says. The reach is what the blur
    /// conversion decides: at twice the intended radius the shadow's darkest
    /// point falls short and what is left smears over twice the distance.
    @Test func aRaisedSurfaceIsShadedBelowAndLitAbove() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 93))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.canvas.cgColor
        let pill = MacStyledSurfaceView(frame: NSRect(x: 30, y: 30, width: 150, height: 33))
        pill.applyStyle(
            fill: Self.chrome,
            cornerRadius: 16.5,
            shadows: [
                .neo(color: Self.shadowDark, offset: CGSize(width: 4, height: -4), blur: 8),
                .neo(color: Self.shadowLight, offset: CGSize(width: -4, height: 4), blur: 8),
            ])
        host.addSubview(pill)

        let lightness = Self.lightnessProbe(of: host)
        let canvasLightness = lightness(5, 5)
        // Bitmap rows are top-down: the pill occupies y 30..63 from the top,
        // so y = 66 is below it on screen and y = 27 above.
        let below = lightness(105, 66)
        let above = lightness(105, 27)

        #expect(below < canvasLightness - 3,
                "below the pill \(below) is not shaded against canvas \(canvasLightness)")
        #expect(above > canvasLightness + 3,
                "above the pill \(above) is not lit against canvas \(canvasLightness)")

        // Neither side may still be running at 15pt out: a doubled radius
        // spreads this far, the intended one has faded.
        #expect(abs(lightness(105, 78) - canvasLightness) < 1.5)
        #expect(abs(lightness(105, 15) - canvasLightness) < 1.5)
    }

    /// A surface asked for no shadows leaves the canvas alone, so a flat
    /// reading elsewhere means an absent shadow rather than a hidden one.
    @Test func aSurfaceWithoutShadowsLeavesTheCanvasFlat() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 93))
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.canvas.cgColor
        let pill = MacStyledSurfaceView(frame: NSRect(x: 30, y: 30, width: 150, height: 33))
        pill.applyStyle(fill: Self.chrome, cornerRadius: 16.5)
        host.addSubview(pill)
        let lightness = Self.lightnessProbe(of: host)
        let canvasLightness = lightness(5, 5)
        #expect(abs(lightness(105, 66) - canvasLightness) < 0.5)
        #expect(abs(lightness(105, 27) - canvasLightness) < 0.5)
    }
}
