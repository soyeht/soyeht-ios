import SwiftUI

/// Cross-platform brand color tokens shared by all targets — iOS app, macOS
/// app, and the SoyehtLiveActivity widget. Values mirror the design system
/// in `app_design.pen`. SwiftUI `Color` so every target consumes them
/// directly; platform-specific UIColor/NSColor tokens live in each target's
/// theme file (`SoyehtTheme.swift`, `MacTheme.swift`).
public enum BrandColors {

    /// Primary brand accent (#00D9A3). Success states, primary CTAs, cursor
    /// caret, active-status indicators.
    public static let accentGreen = Color(hex: "#00D9A3")

    /// Warning / pending accent (#F59E0B). Failed and warning states in the
    /// widget; secondary action highlights.
    public static let accentAmber = Color(hex: "#F59E0B")

    /// Destructive / error accent (#EF4444).
    public static let accentRed = Color(hex: "#EF4444")

    /// Slightly-lifted black surface (#0A0A0A). Dark card surfaces and the
    /// Live Activity banner background on Lock Screen.
    public static let surfaceDeep = Color(hex: "#0A0A0A")

    /// Muted secondary text on dark surfaces (#6B7280).
    public static let textMuted = Color(hex: "#6B7280")
}
