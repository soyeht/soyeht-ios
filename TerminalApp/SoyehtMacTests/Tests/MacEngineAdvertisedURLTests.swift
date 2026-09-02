import XCTest
@testable import SoyehtMacDomain
import SoyehtCore

/// The URL handed to the iPhone during pairing is the one it keeps forever.
/// These pin the rule that a tailnet address always wins, that a LAN address
/// is only ever the fallback, and that neither pairing path asks the
/// `tailscale` CLI anymore.
final class MacEngineAdvertisedURLTests: XCTestCase {
    private let local = URL(string: "http://127.0.0.1:8091")!

    func testTailnetAddressWinsEvenWhenALANAddressExists() {
        let url = MacEngineAdvertisedURL.resolve(
            tailnetIPv4: "100.100.1.7", lanIPv4: "192.168.1.20", localEngineBaseURL: local
        )
        XCTAssertEqual(url.host, "100.100.1.7")
        XCTAssertEqual(url.port, 8091)
    }

    func testLANIsOnlyTheFallback() {
        let url = MacEngineAdvertisedURL.resolve(
            tailnetIPv4: nil, lanIPv4: "192.168.1.20", localEngineBaseURL: local
        )
        XCTAssertEqual(url.host, "192.168.1.20")
        XCTAssertEqual(url.port, 8091)
    }

    func testLoopbackIsTheLastResort() {
        let url = MacEngineAdvertisedURL.resolve(tailnetIPv4: nil, lanIPv4: nil, localEngineBaseURL: local)
        XCTAssertEqual(url, local)
    }

    func testANonTailnetValueInTheTailnetSlotIsNotTrusted() {
        // Defensive: a caller that hands a LAN address as "tailnet" must not
        // get it promoted to the primary answer.
        let url = MacEngineAdvertisedURL.resolve(
            tailnetIPv4: "192.168.1.9", lanIPv4: nil, localEngineBaseURL: local
        )
        XCTAssertEqual(url, local)
    }

    func testATailnetAddressIsNeverOfferedAsLAN() {
        XCTAssertFalse(MacEngineAdvertisedURL.isLANReachableIPv4("100.100.1.7"))
        XCTAssertTrue(MacEngineAdvertisedURL.isLANReachableIPv4("192.168.1.20"))
        XCTAssertFalse(MacEngineAdvertisedURL.lanIPv4Addresses().contains(where: HostClassifier.isTailnetIPv4))
    }

    func testThePortFollowsTheLocalEngine() {
        let dev = URL(string: "http://127.0.0.1:8101")!
        let url = MacEngineAdvertisedURL.resolve(tailnetIPv4: "100.64.0.7", lanIPv4: nil, localEngineBaseURL: dev)
        XCTAssertEqual(url.port, 8101)
    }

    /// On a Mac with Tailscale up this must produce the tailnet address
    /// without ever spawning a process. On one without, it must still
    /// answer — never nil, never hang.
    func testLiveResolutionNeverHangsAndPrefersTheTailnet() {
        let started = Date()
        let url = MacEngineAdvertisedURL.current(localEngineBaseURL: local)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "no subprocess, no 2 s budget")
        if let tailnet = TailnetAddressResolver.currentTailnetIPv4() {
            XCTAssertEqual(url.host, tailnet)
        } else {
            XCTAssertNotNil(url.host)
        }
    }

    // MARK: - Source guards: the CLI is gone from both pairing paths

    func testNeitherPairingPathAsksTheTailscaleCLIForTheMacAddress() throws {
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let reachable = try slice(listener, from: "static func reachableMacEngineURL(", to: "static func notifyClaimed(")
        XCTAssertTrue(reachable.contains("MacEngineAdvertisedURL.current("))
        XCTAssertFalse(reachable.contains("tailscaleStatus()"))
        XCTAssertFalse(reachable.contains("async"), "no subprocess to await")

        let preferences = try macSource("PreferencesDevicesViewController.swift")
        XCTAssertFalse(preferences.contains("/opt/homebrew/bin/tailscale"))
        XCTAssertFalse(preferences.contains("/usr/local/bin/tailscale"))
        XCTAssertFalse(preferences.contains("status\", \"--json\""))
        XCTAssertTrue(preferences.contains("MacEngineAdvertisedURL.current("))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
