import Foundation

/// CIE Lab / LCh color math over hex strings.
///
/// `HexColorMath` blends in sRGB, which is the right tool for mixing two
/// authored colors and the wrong one for moving a role's lightness: scaling
/// channels drags chroma along with the lightness, so darkening a saturated
/// surface bleeds its color out and the result drifts grey. Lab separates the
/// two, so a derived role can change lightness while the material keeps the
/// chroma and hue it started with.
public enum LabColorMath {
    /// Cylindrical Lab: lightness 0...100, chroma from the neutral axis, hue
    /// in degrees.
    public struct LCh: Equatable, Sendable {
        public var lightness: Double
        public var chroma: Double
        public var hue: Double

        public init(lightness: Double, chroma: Double, hue: Double) {
            self.lightness = lightness
            self.chroma = chroma
            self.hue = hue
        }
    }

    public static func lch(of hex: String) -> LCh {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        let (l, a, bb) = lab(linear(r), linear(g), linear(b))
        let chroma = (a * a + bb * bb).squareRoot()
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return LCh(lightness: l, chroma: chroma, hue: hue)
    }

    /// LCh → hex, reduced to the most chroma sRGB can actually show at that
    /// lightness and hue. The gamut is strongly anisotropic — yellow holds its
    /// chroma when bright, blue only when dark — so an unreachable request is
    /// clamped rather than allowed to clip a channel, which would shift the
    /// hue it was asked for.
    public static func hex(_ color: LCh) -> String {
        let lightness = min(100, max(0, color.lightness))
        let hue = color.hue.truncatingRemainder(dividingBy: 360)
        if let exact = srgb(lightness, max(0, color.chroma), hue) {
            return exact
        }
        var low = 0.0
        var high = max(0, color.chroma)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if srgb(lightness, mid, hue) != nil { low = mid } else { high = mid }
        }
        return srgb(lightness, low, hue) ?? clipped(lightness, low, hue)
    }

    /// The most chroma sRGB can show at this lightness and hue. The gamut is
    /// strongly anisotropic, so this varies by a factor of four across the
    /// hue circle and is the reason a fixed "saturation" produces wildly
    /// uneven colorfulness.
    public static func maxChroma(lightness: Double, hue: Double) -> Double {
        lch(of: hex(LCh(lightness: lightness, chroma: 200, hue: hue))).chroma
    }

    /// The same color at a different lightness, keeping chroma and hue: a
    /// surface under more or less light, rather than a surface mixed with
    /// paint.
    public static func withLightness(_ hex: String, _ lightness: Double) -> String {
        var color = lch(of: hex)
        color.lightness = lightness
        return self.hex(color)
    }

    // MARK: - sRGB <-> Lab

    private static let whiteX = 0.95047
    private static let whiteZ = 1.08883
    private static let epsilon = 0.008856
    private static let kappa = 903.3

    private static func linear(_ channel: UInt8) -> Double {
        let c = Double(channel) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / whiteX
        let y =  0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / whiteZ
        func f(_ t: Double) -> Double {
            t > epsilon ? pow(t, 1.0 / 3) : (kappa * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func components(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let radians = h * .pi / 180
        let a = c * cos(radians)
        let b = c * sin(radians)
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        func invert(_ t: Double) -> Double {
            let cubed = t * t * t
            return cubed > epsilon ? cubed : (116 * t - 16) / kappa
        }
        let x = invert(fx) * whiteX
        let y = l > kappa * epsilon ? pow((l + 16) / 116, 3) : l / kappa
        let z = invert(fz) * whiteZ
        return (
             3.2406 * x - 1.5372 * y - 0.4986 * z,
            -0.9689 * x + 1.8758 * y + 0.0415 * z,
             0.0557 * x - 0.2040 * y + 1.0570 * z
        )
    }

    private static func srgb(_ l: Double, _ c: Double, _ h: Double) -> String? {
        let (r, g, b) = components(l, c, h)
        let tolerance = -0.0001...1.0001
        guard tolerance.contains(r), tolerance.contains(g), tolerance.contains(b) else {
            return nil
        }
        return clipped(l, c, h)
    }

    private static func clipped(_ l: Double, _ c: Double, _ h: Double) -> String {
        let (r, g, b) = components(l, c, h)
        func byte(_ value: Double) -> Int {
            Int((min(1, max(0, encode(min(1, max(0, value))))) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
