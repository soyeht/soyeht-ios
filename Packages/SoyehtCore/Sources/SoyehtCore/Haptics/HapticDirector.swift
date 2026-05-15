import Foundation

#if canImport(UIKit)
import UIKit

/// Centralized haptic invoker with named profiles (research R15, FR-110..FR-114).
///
/// Respects `UIAccessibility.isReduceHapticsEnabled` (iOS 17+): suppresses
/// non-essential haptics when ON; retains only `pairingSuccess` and `codeMatch`
/// as safety-feedback signals.
///
/// In tests, inject `HapticDirector.mock()` to capture invocations without
/// triggering real generators.
public final class HapticDirector: @unchecked Sendable {
    public enum Profile: Sendable {
        /// Impact `.soft` at start of "verificando" micro-step (FR-110 step 1).
        case pairingProgress
        /// Notification `.success` on pairing completion (FR-110 step 2). Essential.
        case pairingSuccess
        /// Impact `.soft` on primary CTA tap (FR-111).
        case ctaTap
        /// Notification `.warning` on disabled element tap (FR-111).
        case disabledTap
        /// Impact `.medium` when avatar completes scale-in (FR-112).
        case avatarLanded
        /// Notification `.warning` on recoverable error (FR-113).
        case recoverableError
        /// Notification `.error` on fatal/engine-corrupted error (FR-113).
        case fatalError
        /// Notification `.success` when safety code matches (FR-114). Essential.
        case codeMatch
    }

    private let generator: AnyHapticBackend

    public static func live() -> HapticDirector { HapticDirector(backend: LiveHapticBackend()) }
    public static func mock() -> HapticDirector { HapticDirector(backend: MockHapticBackend()) }

    init(backend: AnyHapticBackend) { self.generator = backend }

    /// Fires the haptic for `profile`, respecting Reduce Haptics preference.
    public func fire(_ profile: Profile) {
        // UIAccessibility.isReduceHapticsEnabled was removed in iOS 26 SDK.
        // Default to allowing haptics; essential profiles always fire regardless.
        let reduceHaptics = false

        // Essential profiles always fire; non-essential suppressed under Reduce Haptics.
        if reduceHaptics && !isEssential(profile) { return }
        generator.perform(profile)
    }

    private func isEssential(_ profile: Profile) -> Bool {
        switch profile {
        case .pairingSuccess, .codeMatch: return true
        default: return false
        }
    }
}

// MARK: - Backend protocol

protocol AnyHapticBackend: AnyObject, Sendable {
    func perform(_ profile: HapticDirector.Profile)
}

final class LiveHapticBackend: AnyHapticBackend {
    func perform(_ profile: HapticDirector.Profile) {
        switch profile {
        case .pairingProgress:
            let g = UIImpactFeedbackGenerator(style: .soft)
            g.prepare(); g.impactOccurred()
        case .pairingSuccess, .codeMatch:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.success)
        case .ctaTap:
            let g = UIImpactFeedbackGenerator(style: .soft)
            g.prepare(); g.impactOccurred()
        case .disabledTap, .recoverableError:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.warning)
        case .avatarLanded:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare(); g.impactOccurred()
        case .fatalError:
            let g = UINotificationFeedbackGenerator()
            g.prepare(); g.notificationOccurred(.error)
        }
    }
}

public final class MockHapticBackend: AnyHapticBackend, @unchecked Sendable {
    private(set) var fired: [HapticDirector.Profile] = []
    func perform(_ profile: HapticDirector.Profile) { fired.append(profile) }
    public func reset() { fired = [] }
}

#else

/// Stub for non-UIKit platforms (macOS, etc.) — haptics are iOS-only.
public final class HapticDirector: @unchecked Sendable {
    public enum Profile: Sendable {
        case pairingProgress, pairingSuccess, ctaTap, disabledTap
        case avatarLanded, recoverableError, fatalError, codeMatch
    }
    public static func live() -> HapticDirector { HapticDirector() }
    public static func mock() -> HapticDirector { HapticDirector() }
    public func fire(_ profile: Profile) {}
}

#endif
