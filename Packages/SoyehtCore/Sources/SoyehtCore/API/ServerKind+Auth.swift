import Foundation

extension ServerKind {
    /// Sets the session-token header on `request` using the shape this
    /// server kind expects:
    /// - `.engine` → `Authorization: Bearer <token>`
    /// - `.adminHost` → `Cookie: soyeht_session=<token>` (the admin host's
    ///   session middleware reads the cookie jar; `URLSession` will also
    ///   attach cookies from `HTTPCookieStorage` automatically when
    ///   present, but we set the header explicitly so direct callers —
    ///   probes, tests with a mocked `URLSession` — work without seeding
    ///   the jar)
    ///
    /// Single source of truth for the auth-header rule. Behavior dispatched
    /// on `ServerKind` belongs on `ServerKind`; the exhaustive switch makes
    /// adding a third kind a one-place change.
    func applyAuth(to request: inout URLRequest, token: String) {
        switch self {
        case .engine:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .adminHost:
            request.setValue("soyeht_session=\(token)", forHTTPHeaderField: "Cookie")
        }
    }
}
