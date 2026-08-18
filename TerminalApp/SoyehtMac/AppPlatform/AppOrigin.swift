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
/// this type fixes was written in the first place. **That deletion is the
/// defence**; what follows is depth on top of it.
///
/// `AppOriginTests` sweeps production source for the scheme prefix and
/// requires **this file to be the only one that contains it at all** — in code
/// or in prose. Earlier versions searched for one spelling at a time, first the
/// interpolation and then the quoted literal, and each was killed by a producer
/// written in the next spelling: `+` for the first, a multi-line string for the
/// second. Chasing spellings is a losing shape, because Swift keeps having more
/// of them; the bare prefix is contained by every producer regardless.
///
/// Hence the rule that this file is the sole place that may even mention the
/// prefix: other files point here instead of restating the format. That is the
/// single-producer rule applied to documentation, and it is not cosmetic —
/// restating the format in prose is how phase 2b kept describing the origin as
/// `<id>` long after phase 2a had moved to the install identity.
///
/// One limit survives, pinned by a failing expectation in the tests rather than
/// left to a reader's optimism: a prefix assembled from pieces escapes. That is
/// someone working around the guard, not the refactor nobody reviewed.
struct AppOrigin: Hashable {
    /// Custom-scheme origins report host `local` and port 0. The bridge's
    /// principal check compares this exact triple, never a prefix.
    static let host = "local"

    let scheme: String

    init(installID: String) {
        scheme = "soyehtapp-\(installID)"
    }
}
