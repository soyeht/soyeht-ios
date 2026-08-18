import Foundation

/// The origin an installed app's web content runs under.
///
/// **Minted from the installer-issued install ID, never from anything the
/// bundle declares.** A manifest is data supplied by the very thing being
/// isolated. If a declared field selects the origin, two bundles can claim
/// the same one — and because app panes share a persistent website data
/// store, that is a single shared origin rather than two isolated ones: the
/// second app reads the first app's storage. Same-origin policy stops being
/// the thing that separates apps and becomes a thing the manifest chooses.
///
/// The install ID is a UUID minted by `AppInstallStore.install`, so distinct
/// installs cannot collide even when their manifests declare the same `id`.
/// That is a property of how the value is produced, not a check performed on
/// it: there is no collision path left to detect.
///
/// This type is the **only** producer of an app scheme. There is deliberately
/// no `scheme(for:)` taking a loose `String`, because such a parameter is an
/// invitation to hand it a declared field — which is exactly how the defect
/// this type fixes was written in the first place.
/// `AppOriginSourceGuardTests` pins that uniqueness, so a second producer
/// cannot appear in a file nobody thought to review.
struct AppOrigin: Hashable {
    /// Custom-scheme origins report host `local` and port 0. The bridge's
    /// principal check compares this exact triple, never a prefix.
    static let host = "local"

    let scheme: String

    init(installID: String) {
        scheme = "soyehtapp-\(installID)"
    }
}
