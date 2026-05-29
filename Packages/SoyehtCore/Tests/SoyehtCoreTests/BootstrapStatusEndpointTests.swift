import XCTest
@testable import SoyehtCore

/// Transport rules for the raw-engine `/bootstrap/status` endpoint.
///
/// Regression coverage for the Claw Store readiness gate falling to
/// "Cannot check this Mac yet": it used to build `https://<mac>:8091` (TLS-fails)
/// or reuse the 443 proxy (404s on `/bootstrap/*`). The single resolver must
/// route tailnet/bare hosts to plain `http://host:8091` and keep real domains on
/// https — and must NEVER produce `https://host:8091`.
final class BootstrapStatusEndpointTests: XCTestCase {

    private func resolve(_ host: String) -> URL? {
        BootstrapStatusEndpoint.baseURL(forHost: host)
    }

    // ── Tailnet / tailscale-serve host ───────────────────────────────────────

    func test_tailscaleServeURL_resolvesToHttp8091_notHttps() {
        let url = resolve("https://macstudio.tail295ab5.ts.net")
        XCTAssertEqual(url?.scheme, "http", "tailnet serve URL must downgrade to plain http on :8091")
        XCTAssertEqual(url?.host, "macstudio.tail295ab5.ts.net")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_tailscaleMagicDNSBareHost_resolvesToHttp8091() {
        let url = resolve("macstudio.tail295ab5.ts.net")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_cgnatTailnetIP_resolvesToHttp8091() {
        let url = resolve("100.66.202.16")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "100.66.202.16")
        XCTAssertEqual(url?.port, 8091)
    }

    // ── The exact bug: never https://host:8091 ───────────────────────────────

    func test_explicitHttps8091_isForcedToHttp() {
        let url = resolve("https://macstudio.tail295ab5.ts.net:8091")
        XCTAssertEqual(url?.scheme, "http", "the engine port is plain HTTP; https:8091 must be corrected to http")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_neverProducesHttpsOn8091_acrossInputs() {
        for host in [
            "https://macstudio.tail295ab5.ts.net",
            "https://macstudio.tail295ab5.ts.net:8091",
            "macstudio.tail295ab5.ts.net",
            "100.66.202.16",
            "100.66.202.16:8091",
            "192.168.15.13",
            "nixos.local",
        ] {
            let url = resolve(host)
            XCTAssertFalse(url?.scheme == "https" && url?.port == 8091,
                           "must never build https://\(host):8091, got \(url?.absoluteString ?? "nil")")
        }
    }

    // ── Bare LAN host / IP ───────────────────────────────────────────────────

    func test_bareLanIP_resolvesToHttp8091() {
        let url = resolve("192.168.15.13")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "192.168.15.13")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_bareHostWithExplicitPort_keepsPortOverHttp() {
        let url = resolve("100.66.202.16:9000")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.port, 9000)
    }

    // ── Real domain / Caddy on 443 — must NOT regress ────────────────────────

    func test_realDomainHttps_keepsHttps443() {
        let url = resolve("https://casa.example.com")
        XCTAssertEqual(url?.scheme, "https", "a real domain (Caddy on 443) must stay https")
        XCTAssertEqual(url?.host, "casa.example.com")
        XCTAssertNil(url?.port, "default 443 (no explicit port) for a domain proxy")
    }

    func test_realDomainHttpsCustomPort_keepsHttpsAndPort() {
        let url = resolve("https://casa.example.com:8443")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.port, 8443)
    }

    // ── http inputs / edge cases ─────────────────────────────────────────────

    func test_httpURL_keptAsHttp() {
        let url = resolve("http://192.168.1.5:8091")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_localhost_resolvesToHttp8091() {
        let url = resolve("localhost")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "localhost")
        XCTAssertEqual(url?.port, 8091)
    }

    func test_emptyHost_returnsNil() {
        XCTAssertNil(resolve("   "))
        XCTAssertNil(resolve(""))
    }
}
