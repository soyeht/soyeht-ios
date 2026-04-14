import CoreGraphics

// iOS rubber-band (bounce-at-limit) curve.
//
// When a value is dragged past a limit, we want the overshoot to shrink as
// the user pulls further — matching the feel of UIScrollView's edge bounce.
// Apple uses `f(x) = (1 - 1 / (x * c / d + 1)) * d` with `c = 0.55`, where:
//   - `x` is the raw distance past the limit (positive).
//   - `d` is the maximum allowed overshoot (dimension).
//   - `c` is the stiffness coefficient; 0.55 matches iOS scroll views.
// The result is the actual visual offset to apply: same sign as `offset`,
// never larger than `dimension`.
enum RubberBand {
    static let defaultCoefficient: CGFloat = 0.55

    static func offset(
        rawOffset: CGFloat,
        dimension: CGFloat,
        coefficient: CGFloat = defaultCoefficient
    ) -> CGFloat {
        guard rawOffset != 0, dimension > 0 else { return 0 }
        let magnitude = abs(rawOffset)
        let scaled = (1 - (1 / ((magnitude * coefficient / dimension) + 1))) * dimension
        return rawOffset < 0 ? -scaled : scaled
    }
}
