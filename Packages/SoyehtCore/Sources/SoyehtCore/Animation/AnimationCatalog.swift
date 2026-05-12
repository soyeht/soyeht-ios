import SwiftUI

/// Typed animation tokens for all onboarding scenes (research R14).
///
/// Every scene consumes tokens from this catalog — no hardcoded curves in views.
/// Reduce Motion overrides are the single source of truth here (FR-082, FR-100..FR-129).
public enum AnimationCatalog {
    // MARK: - Tokens

    /// Between-scene push/pop transition (FR-100).
    /// Reduce Motion → `.easeInOut(duration: 0.2)`.
    public static func sceneTransition(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.42, dampingFraction: 0.85)
    }

    /// "Chave girando" during house creation (FR-101). Total 2.4–3.0s, 4 micro-steps.
    /// Reduce Motion → `.linear(duration: 0.3)` cross-fade.
    public static func keyForging(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .linear(duration: 0.3)
            : .timingCurve(0.2, 0.0, 0.8, 1.0, duration: 2.7)
    }

    /// Carousel page-dot morphing (FR-102).
    /// Reduce Motion → `.easeInOut(duration: 0.2)`.
    public static func carouselPageDot(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.32, dampingFraction: 0.78)
    }

    /// House avatar scale-in reveal (FR-103). Scale 0.6→1.0.
    /// Reduce Motion → `.easeInOut(duration: 0.2)`.
    public static func avatarReveal(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.5, dampingFraction: 0.7)
    }

    /// Confetti burst for the first-resident card (FR-104). Total ≤1.2s.
    /// Reduce Motion → `.easeOut(duration: 0.3)`.
    public static func confettiBurst(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.3)
            : .linear(duration: 1.2)
    }

    /// CTA button momentary compress (FR-106). ≤120ms.
    /// Reduce Motion → `.easeOut(duration: 0.08)`.
    public static func buttonPress(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.08)
            : .spring(response: 0.12, dampingFraction: 0.65)
    }

    /// 6-word safety code stagger reveal (FR-128). 60ms between words, total 0.36s.
    /// Reduce Motion → single cross-fade at 0.2s.
    public static func staggerWord(wordIndex: Int, reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .linear(duration: 0.1).delay(Double(wordIndex) * 0.06)
    }

    /// Safety glow after code confirmation (FR-129). 0.4s.
    /// Reduce Motion → `.linear(duration: 0.15)`.
    public static func safetyGlow(reduceMotion: Bool = false) -> Animation {
        reduceMotion
            ? .linear(duration: 0.15)
            : .easeInOut(duration: 0.4)
    }
}

// MARK: - Duration constants

extension AnimationCatalog {
    public enum Duration {
        public static let keyForgingTotal: TimeInterval = 2.7
        public static let keyForgingStep: TimeInterval = keyForgingTotal / 4
        public static let confettiBurst: TimeInterval = 1.2
        public static let avatarRevealGlow: TimeInterval = 0.6
    }
}
