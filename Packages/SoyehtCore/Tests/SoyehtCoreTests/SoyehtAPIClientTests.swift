import Testing
import Foundation
@testable import SoyehtCore

/// Pinning tests for `SoyehtAPIClient.isLocalHost`. The classifier drives
/// the http/https and ws/wss decision app-wide — a false positive here
/// silently downgrades remote traffic to plaintext. These cases lock in
/// the post-2026-05 Tailscale carve-out (CGNAT 100.64.0.0/10 and the
/// MagicDNS `.ts.net` suffix are both treated as remote).
@Suite struct SoyehtAPIClientIsLocalHostTests {

    // MARK: - Should classify as local

    @Test func loopbackIsLocal() {
        #expect(SoyehtAPIClient.isLocalHost("localhost"))
        #expect(SoyehtAPIClient.isLocalHost("localhost:8892"))
        #expect(SoyehtAPIClient.isLocalHost("127.0.0.1"))
        #expect(SoyehtAPIClient.isLocalHost("127.0.0.1:9000"))
    }

    @Test func bonjourIsLocal() {
        #expect(SoyehtAPIClient.isLocalHost("foo.local"))
        #expect(SoyehtAPIClient.isLocalHost("my-mac.local:8080"))
    }

    @Test func rfc1918IsLocal() {
        #expect(SoyehtAPIClient.isLocalHost("192.168.1.10"))
        #expect(SoyehtAPIClient.isLocalHost("10.0.0.5:443"))
        #expect(SoyehtAPIClient.isLocalHost("172.16.0.1"))
        #expect(SoyehtAPIClient.isLocalHost("172.31.255.255"))
    }

    // MARK: - Should NOT classify as local

    @Test func tailscaleCGNATIsRemote() {
        // 100.64.0.0/10 — Tailscale tailnet IPs. The overlay encrypts at the
        // network layer but the app cannot verify the daemon is active, so
        // the WebSocket / HTTP handshake itself must be wrapped in TLS.
        #expect(!SoyehtAPIClient.isLocalHost("100.64.0.1"))
        #expect(!SoyehtAPIClient.isLocalHost("100.96.42.1"))
        #expect(!SoyehtAPIClient.isLocalHost("100.127.255.254:8080"))
    }

    @Test func tailscaleMagicDNSIsRemote() {
        // *.ts.net — Tailscale MagicDNS. Same plaintext-handshake concern as
        // CGNAT addresses; users must run `tailscale cert` and serve TLS.
        #expect(!SoyehtAPIClient.isLocalHost("mac.tailnet.ts.net"))
        #expect(!SoyehtAPIClient.isLocalHost("foo.ts.net:8443"))
    }

    @Test func publicAddressesAreRemote() {
        #expect(!SoyehtAPIClient.isLocalHost("api.example.com"))
        #expect(!SoyehtAPIClient.isLocalHost("8.8.8.8"))
        #expect(!SoyehtAPIClient.isLocalHost("172.15.0.1"))    // outside RFC1918
        #expect(!SoyehtAPIClient.isLocalHost("172.32.0.1"))    // outside RFC1918
    }

    // MARK: - buildURL scheme decision

    @Test func buildURLUsesHTTPSForRemote() throws {
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "api.example.com", path: "/health")
        #expect(url.scheme == "https")
    }

    @Test func buildURLUsesHTTPForLoopback() throws {
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "localhost:8892", path: "/health")
        #expect(url.scheme == "http")
    }

    @Test func buildURLUsesHTTPSForTailscaleCGNAT() throws {
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "100.64.0.1:8443", path: "/health")
        #expect(url.scheme == "https")
    }

    @Test func buildURLUsesHTTPSForTailscaleMagicDNS() throws {
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "mac.tailnet.ts.net", path: "/health")
        #expect(url.scheme == "https")
    }

    // MARK: - buildURL scheme stripping (audit task #18)

    @Test func buildURLStripsCallerHTTPSPrefixAndKeepsHTTPSForRemote() throws {
        // Caller passes a scheme on the host string. The decision must
        // still come from `isLocalHost`, not from whatever the caller
        // typed — otherwise a caller could downgrade to plaintext by
        // handing in `http://api.example.com`.
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "https://api.example.com", path: "/health")
        #expect(url.scheme == "https")
        #expect(url.host == "api.example.com")
        #expect(url.path == "/health")
    }

    @Test func buildURLStripsCallerHTTPPrefixAndUpgradesRemoteToHTTPS() throws {
        // The previous shape would have honored the caller's `http://`
        // for a remote host, silently emitting plaintext. Now the scheme
        // is re-derived: remote → https.
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "http://api.example.com", path: "/health")
        #expect(url.scheme == "https")
        #expect(url.host == "api.example.com")
    }

    @Test func buildURLStripsCallerHTTPSPrefixForLocalhost() throws {
        // Symmetrical: a caller that passes `https://localhost` for a
        // local port that doesn't terminate TLS used to get a `https://`
        // URL it could never connect to. Now the scheme is re-derived
        // and matches what the local listener actually serves.
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "https://localhost:8892", path: "/health")
        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port == 8892)
    }

    @Test func buildURLPathPreservedAfterStripping() throws {
        let client = SoyehtAPIClient.shared
        let url = try client.buildURL(host: "http://10.0.0.5:9000", path: "/api/v1/something")
        #expect(url.scheme == "http")  // 10.x is local
        #expect(url.host == "10.0.0.5")
        #expect(url.port == 9000)
        #expect(url.path == "/api/v1/something")
    }
}

/// `APIErrorBody.init(from:)` decodes the optional `reasons` array via
/// `do/catch` rather than `try?` so a malformed entry produces a log
/// breadcrumb without losing the rest of the envelope (the `error`
/// string and any other fields). Pins the codable-audit P0 fix
/// (2026-05-08) — a future refactor that "simplifies" the decoder back
/// to a bare `try?` would silently regress operator triage in
/// production.
///
/// Wire format note: the production server emits snake_case keys
/// (`retry_after_secs`) and the production decoder applies
/// `.convertFromSnakeCase` to map them to the Swift camelCase
/// `CodingKeys` (`retryAfterSecs`). The tests below use the
/// production-configured decoder via `SoyehtAPIClient.shared.decoder`
/// — feeding camelCase JSON through a default decoder would
/// regression-pin a parallel path the production code never takes.
/// Likewise the `UnavailReason` test fixtures use real tag strings
/// (`install_in_progress`, etc.) so the test does not silently
/// validate the `default: self = .unknownType` fallback at
/// `UnavailReason.swift:24`.
@Suite struct SoyehtAPIClientErrorBodyTests {
    /// Mirrors the production `SoyehtAPIClient.decoder` configuration —
    /// `keyDecodingStrategy = .convertFromSnakeCase`. If production
    /// changes its strategy, these tests need to track it; without the
    /// match, every test below exercises a parallel decode path that
    /// production never takes.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    @Test func decodesValidEnvelopeWithReasons() throws {
        // `install_in_progress` is a real `UnavailReason` discriminator
        // (`UnavailReason.swift:20`); `percent: 50` round-trips to the
        // `installInProgress(percent:)` associated value. If a future
        // refactor removes the `default: self = .unknownType` fallback,
        // this test still passes because it does not depend on the
        // fallback.
        let json = """
        {
          "error": "service_unavailable",
          "code": "claws_blocked",
          "reasons": [{"type": "install_in_progress", "percent": 50}],
          "retry_after_secs": 5
        }
        """
        let body = try decoder.decode(SoyehtAPIClient.APIErrorBody.self, from: Data(json.utf8))
        #expect(body.error == "service_unavailable")
        #expect(body.code == "claws_blocked")
        #expect(body.reasons == [.installInProgress(percent: 50)])
        #expect(body.retryAfterSecs == 5)
    }

    @Test func tolerateMalformedReasonsKeepsRestOfEnvelope() throws {
        // The `reasons` array contains an entry without the required
        // `type` discriminator. `UnavailReason.init(from:)` throws
        // `keyNotFound(.type)` for this shape — exactly the malformed
        // case the bare `try?` used to swallow silently. The decoder
        // catches, logs, and falls back to nil — the rest of the
        // envelope (`error`, `code`, `retry_after_secs`) must still
        // surface.
        let json = """
        {
          "error": "service_unavailable",
          "code": "claws_blocked",
          "reasons": [{"unknown_field": "garbage"}],
          "retry_after_secs": 12
        }
        """
        let body = try decoder.decode(SoyehtAPIClient.APIErrorBody.self, from: Data(json.utf8))
        #expect(body.error == "service_unavailable")
        #expect(body.code == "claws_blocked")
        #expect(body.retryAfterSecs == 12)
        #expect(body.reasons == nil) // tolerated, not surfaced as decode failure
    }

    @Test func envelopeWithoutReasonsIsAccepted() throws {
        // `reasons` is `decodeIfPresent` so the absence is legal.
        let json = """
        {
          "error": "rate_limited",
          "retry_after_secs": 60
        }
        """
        let body = try decoder.decode(SoyehtAPIClient.APIErrorBody.self, from: Data(json.utf8))
        #expect(body.error == "rate_limited")
        #expect(body.code == nil)
        #expect(body.reasons == nil)
        #expect(body.retryAfterSecs == 60)
    }

    @Test func missingRequiredErrorFieldStillFails() throws {
        // The `error` string is required; no envelope without it is
        // valid. The toleration policy on `reasons` must not generalise
        // to other required fields.
        let json = """
        {
          "code": "missing_error_field"
        }
        """
        do {
            _ = try decoder.decode(SoyehtAPIClient.APIErrorBody.self, from: Data(json.utf8))
            Issue.record("Expected decode failure on missing `error` field")
        } catch {
            // expected
        }
    }
}
