import SwiftUI

/// SwiftUI environment key for `SoyehtIdentity`. Lets previews and
/// snapshot tests inject a fixture instance without touching the
/// process-wide singleton. Default resolves to `SoyehtIdentity.shared`,
/// so call sites that don't override the environment continue to read
/// the real identity.
///
/// Usage:
/// ```
/// // In production view:
/// @Environment(\.soyehtIdentity) private var identity
///
/// // In preview / test:
/// SomeView()
///     .environment(\.soyehtIdentity, fixtureIdentity)
/// ```
///
/// Most existing call sites in PR-1 use `@ObservedObject private var
/// identity = SoyehtIdentity.shared` directly because they were
/// already on a singleton; the environment hook is provided for new
/// previewable views going forward.
private struct SoyehtIdentityKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: SoyehtIdentity = .shared
}

extension EnvironmentValues {
    var soyehtIdentity: SoyehtIdentity {
        get { self[SoyehtIdentityKey.self] }
        set { self[SoyehtIdentityKey.self] = newValue }
    }
}
