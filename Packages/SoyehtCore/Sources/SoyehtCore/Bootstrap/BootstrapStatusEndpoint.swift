import Darwin
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
    /// The engine's plain-HTTP bootstrap port.
    public static let enginePort = 8091

    /// Resolve the `/bootstrap/status` base URL (scheme + host + port, no path)
    /// for a server host string. Returns `nil` only for an empty/unparseable host.
    public static func baseURL(forHost rawHost: String) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var scheme: String?
        var host = trimmed
        var explicitPort: Int?

        if let url = URL(string: trimmed),
           let parsedScheme = url.scheme?.lowercased(),
           parsedScheme == "http" || parsedScheme == "https",
           let parsedHost = url.host {
            scheme = parsedScheme
            host = parsedHost
            explicitPort = url.port
        } else if !trimmed.hasPrefix("["),
                  let colon = trimmed.lastIndex(of: ":"),
                  trimmed[..<colon].contains(":") == false,
                  let parsedPort = Int(trimmed[trimmed.index(after: colon)...]) {
            // bare `host:port` (not IPv6, single colon)
            host = String(trimmed[..<colon])
            explicitPort = parsedPort
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        // Real domain over https on its own (non-engine) port → keep the proxy as-is.
        if scheme == "https", !isTailnetHost(host), explicitPort != enginePort {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.port = explicitPort // nil ⇒ default 443
            return components.url
        }

        // Raw engine: plain HTTP on the engine port (8091 unless explicitly set).
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = explicitPort ?? enginePort
        return components.url
    }

    /// A tailnet address: a MagicDNS name (`*.ts.net`) or a CGNAT IPv4 in
    /// `100.64.0.0/10`, or a Tailscale ULA IPv6 address in
    /// `fd7a:115c:a1e0::/48`. The tailscale-serve HTTPS proxy on such hosts
    /// does not expose `/bootstrap/*`, so the raw engine port must be used over
    /// plain HTTP.
    static func isTailnetHost(_ host: String) -> Bool {
        let lower = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if lower.hasSuffix(".ts.net") { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4,
           let a = Int(parts[0]), let b = Int(parts[1]),
           Int(parts[2]) != nil, Int(parts[3]) != nil,
           a == 100, (64...127).contains(b) {
            return true
        }
        if isTailscaleIPv6(lower) {
            return true
        }
        return false
    }

    private static func isTailscaleIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: address) { bytes in
            guard bytes.count >= 6 else { return false }
            return bytes[0] == 0xfd
                && bytes[1] == 0x7a
                && bytes[2] == 0x11
                && bytes[3] == 0x5c
                && bytes[4] == 0xa1
                && bytes[5] == 0xe0
        }
    }
}
