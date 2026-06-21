import Foundation

/// Single source of truth for turning a server host string into the base URL of
/// the **raw engine** `GET /bootstrap/status` endpoint.
///
/// The bootstrap endpoint is deliberately NOT the authenticated household API
/// (the 443 reverse-proxy used for `/api/v1/*`, built by
/// `URL.householdEndpoint(fromHost:)`). It is the engine's own port (8091),
/// which speaks **plain HTTP** and is reached directly over the tailnet
/// (MagicDNS / `100.64.0.0/10`). Two URLs that must never be produced for
/// `/bootstrap/status`:
///   - `https://host:8091` — the engine port is plain HTTP; HTTPS there fails the
///     TLS handshake (`tlsv1 alert protocol version`).
///   - the 443 tailscale-serve / Caddy proxy for a *tailnet* host — it fronts the
///     admin port and returns 404 for `/bootstrap/*`.
///
/// Rules:
///   - Tailnet host (`*.ts.net` or a `100.64.0.0/10` CGNAT IP), a bare host/IP, an
///     `http` URL, or any host with an explicit `:8091` → `http://host:8091`.
///   - A real domain over `https` (e.g. a Caddy deployment on 443, or a custom
///     https port) keeps `https` and its port → `https://domain[:port]`.
public enum BootstrapStatusEndpoint {
    /// Legacy release-profile engine bootstrap port. New code should use
    /// `enginePort(for:)` or `EndpointPolicy.defaultBootstrapPort(for:)` so
    /// Dev and release profiles do not drift.
    @available(*, deprecated, message: "Use enginePort(for:) or EndpointPolicy.defaultBootstrapPort(for:) for profile-aware ports.")
    public static let enginePort = SoyehtInstallProfile.release.bootstrapPort

    public static func enginePort(for profile: SoyehtInstallProfile = .current) -> Int {
        EndpointPolicy.defaultBootstrapPort(for: profile)
    }

    /// Resolve the `/bootstrap/status` base URL (scheme + host + port, no path)
    /// for a server host string. Returns `nil` only for an empty/unparseable host.
    public static func baseURL(
        forHost rawHost: String,
        installProfile: SoyehtInstallProfile = .current
    ) -> URL? {
        EndpointPolicy.bootstrapStatusBaseURL(
            forHost: rawHost,
            installProfile: installProfile
        )
    }

    /// A tailnet address: a MagicDNS name (`*.ts.net`) or a CGNAT IPv4 in
    /// `100.64.0.0/10`, or a Tailscale ULA IPv6 address in
    /// `fd7a:115c:a1e0::/48`. The tailscale-serve HTTPS proxy on such hosts
    /// does not expose `/bootstrap/*`, so the raw engine port must be used over
    /// plain HTTP.
    static func isTailnetHost(_ host: String) -> Bool {
        EndpointPolicy.isTailnetHost(host)
    }
}
