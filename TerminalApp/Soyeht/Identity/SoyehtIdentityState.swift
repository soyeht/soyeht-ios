import Foundation

/// Quad-state describing whether this iPhone has a usable Soyeht identity.
///
/// Replaces the implicit `try? HouseholdSessionStore().load() != nil`
/// pattern that collapsed three distinct conditions into a single Bool:
/// "no entry exists", "Keychain entry exists but decode failed", and
/// "Keychain is locked / protected data unavailable". The first should
/// route the user to onboarding; the second is a corruption signal that
/// should be logged loudly; the third is transient and resolves on
/// first device unlock (`UIApplication.protectedDataDidBecomeAvailableNotification`).
///
/// `SoyehtIdentity.state` is the single observable surface. UI that
/// only needs a yes/no answer can read `.isActive`. UI that needs to
/// route around the unavailable cases reads `.state` directly.
enum SoyehtIdentityState: Equatable, Sendable {
    /// Pre-resolve. `SoyehtIdentity.reload()` has not been called yet
    /// in this process. Treat as "not yet known" — UI that fans out
    /// from this state should wait for a non-`.unknown` value or call
    /// `reload()` itself.
    case unknown

    /// Confirmed absence of any local Soyeht identity. Keychain returned
    /// `nil` (not throw) AND `isProtectedDataAvailable == true`. Route
    /// to onboarding.
    case inactive

    /// A valid identity snapshot is loaded.
    case active(SoyehtIdentitySnapshot)

    /// Could not decide between `.active` and `.inactive`. Caller should
    /// not treat this as `.inactive` — it is a transient or corrupt
    /// state and the user may already be paired.
    case unavailable(UnavailableReason)

    /// Reason the state could not be resolved.
    enum UnavailableReason: Equatable, Sendable {
        /// `UIApplication.shared.isProtectedDataAvailable == false`.
        /// Common on cold launch before first device unlock. Resolves
        /// automatically via the `protectedDataDidBecomeAvailable`
        /// observer in `SoyehtIdentity`.
        case protectedDataUnavailable

        /// `HouseholdSessionStore.load()` threw
        /// `HouseholdSessionError.decodingFailed`. The Keychain entry
        /// exists but is malformed. Should be logged loudly — see the
        /// existing patterns in `AppDelegate.hasAnySetupState()` and
        /// `InstanceListView.hasHouseholdSession`. Caller decides
        /// whether to treat as `.inactive` or surface as a hard error.
        case decodingFailed
    }
}

extension SoyehtIdentityState {
    /// Snapshot if the state is `.active`; otherwise `nil`. Convenience
    /// for UI that only renders content when an identity exists.
    var snapshot: SoyehtIdentitySnapshot? {
        if case .active(let snapshot) = self { return snapshot }
        return nil
    }

    /// `true` only for `.active`. `.unknown` and `.unavailable` both
    /// return `false` — UI must NOT treat `.unavailable` as "logged in"
    /// because the user might be without a key locally even if the
    /// Keychain entry is corrupt.
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
