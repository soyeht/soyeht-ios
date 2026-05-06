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
}
