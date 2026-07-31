import CryptoKit
import XCTest

@testable import Soyeht

final class RelayStreamIPTunnelNetworkSettingsTests: XCTestCase {
    func testBuildsPoolRouteWithoutInstallingDefaultRoute() throws {
        let settings = try RelayStreamIPTunnelNetworkSettings.make(
            assignment: RelayStreamIPv4Assignment(
                address: "192.0.2.2",
                prefixLength: 24,
                peer: "192.0.2.3"
            ),
            mtu: 1_280,
            sessionID: "session-alpha"
        )

        XCTAssertEqual(settings.tunnelRemoteAddress, "192.0.2.3")
        XCTAssertEqual(settings.mtu, 1_280)
        let ipv4 = try XCTUnwrap(settings.ipv4Settings)
        XCTAssertEqual(ipv4.addresses, ["192.0.2.2"])
        XCTAssertEqual(ipv4.subnetMasks, ["255.255.255.0"])
        let route = try XCTUnwrap(ipv4.includedRoutes?.only)
        XCTAssertEqual(route.destinationAddress, "192.0.2.0")
        XCTAssertEqual(route.destinationSubnetMask, "255.255.255.0")
        XCTAssertNotEqual(route.destinationAddress, "0.0.0.0")
        XCTAssertNotEqual(route.destinationSubnetMask, "0.0.0.0")
        XCTAssertNil(settings.ipv6Settings)
    }

    func testRejectsDefaultRouteAndPeerOutsideAuthenticatedPool() {
        assertRejected(
            address: "192.0.2.2",
            prefixLength: 0,
            peer: "192.0.2.3",
            expected: .invalidPrefix
        )
        assertRejected(
            address: "192.0.2.2",
            prefixLength: 24,
            peer: "198.51.100.3",
            expected: .peerOutsidePool
        )
    }

    func testAcceptsPointToPoint31PoolWithoutWideningRoute() throws {
        let settings = try RelayStreamIPTunnelNetworkSettings.make(
            assignment: RelayStreamIPv4Assignment(
                address: "192.0.2.2",
                prefixLength: 31,
                peer: "192.0.2.3"
            ),
            mtu: 1_280,
            sessionID: "session-alpha"
        )

        let route = try XCTUnwrap(settings.ipv4Settings?.includedRoutes?.only)
        XCTAssertEqual(route.destinationAddress, "192.0.2.2")
        XCTAssertEqual(route.destinationSubnetMask, "255.255.255.254")
    }

    func testRejectsNetworkBroadcastAndNonUnicastAssignments() {
        for address in [
            "192.0.2.0",
            "192.0.2.255",
            "0.42.0.2",
            "127.0.0.1",
            "169.254.1.1",
            "224.0.0.1",
        ] {
            assertRejected(
                address: address,
                prefixLength: 24,
                peer: "192.0.2.3",
                expected: .unusableHost
            )
        }
    }

    private func assertRejected(
        address: String,
        prefixLength: UInt8,
        peer: String,
        expected: RelayStreamIPTunnelNetworkSettingsError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RelayStreamIPTunnelNetworkSettings.make(
                assignment: RelayStreamIPv4Assignment(
                    address: address,
                    prefixLength: prefixLength,
                    peer: peer
                ),
                mtu: 1_280,
                sessionID: "session-alpha"
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? RelayStreamIPTunnelNetworkSettingsError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

// MARK: - Validator parity table
//
// The route-scope rules are implemented TWICE, in two languages: here in
// `RelayStreamIPTunnelNetworkSettings.make`, and in the Rust
// `validate_ip_tunnel_network_settings`. Nothing in the build forces them to
// agree, so ONE physical table drives both. This is the Swift consumer; the
// Rust consumer reads the SAME file.
//
// THE TWO ARE NOT SYMMETRIC. Rust is strictly stricter — it additionally binds
// mtu/session by equality to the auth TunnelAck and restricts the session-id
// charset. Those rows are `rust_only` and are deliberately NOT executed here;
// asserting them would invent a contract this side does not hold. `swift_only`
// is empty by measurement, and the table still declares it so that the day
// Swift acquires a rule of its own, the empty declaration fails.
//
// ASYMMETRIC ENFORCEMENT, recorded rather than left implicit: this side pins
// the file's SHA-256, the Rust side cannot (its crate has no reachable SHA-256
// and adding one would mean a new dependency). A semantic row change fails on
// both sides; a whitespace-or-comment-only edit fails only here.
final class RelayStreamIPTunnelValidatorParityTests: XCTestCase {
    private static let tableDigest =
        "e86e388876d7e20c82a78a8124b73393a294ad2fcad0e6e675341941490a4deb"
    private static let total = "33"
    private static let counts = "both=23\trust_only=10\tswift_only=0"
    private static let orderBoth = "b_valid_slash30,b_valid_slash31,b_valid_slash24,b_addr_equals_peer,b_peer_outside_prefix,b_addr_is_network,b_addr_is_broadcast,b_peer_is_network,b_peer_is_broadcast,b_prefix_zero,b_prefix_32,b_addr_all_zero,b_addr_all_ones,b_addr_zero_first_octet,b_addr_loopback,b_addr_link_local,b_addr_multicast,b_peer_loopback,s_mtu_below_min,s_mtu_min,s_mtu_max,s_mtu_above_max,s_session_empty"
    private static let orderRustOnly = "r_ack_matches,r_mtu_mismatch,r_session_mismatch,r_mtu_and_session_mismatch,r_session_whitespace_only,r_session_leading_ws,r_session_trailing_ws,r_session_interior_ws,r_session_forbidden_punct,r_session_underscore_ok"
    private static let orderSwiftOnly = ""
    private static let header = "case_id\taddr\tprefix_len\tpeer\tsettings_mtu\tsettings_session_id\tack_mtu\tack_session_id\tapplies_to\trust_expect\tswift_expect"

    private struct Row {
        let caseID: String
        let addr: String
        let prefixLength: UInt8
        let peer: String
        let settingsMTU: UInt16
        let settingsSessionID: String
        let appliesTo: String
        let swiftExpect: String
    }

    /// Same repo-relative idiom the other SoyehtTests suites use: the fixture is
    /// read physically, not duplicated as literals.
    private func tableURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SoyehtTests/
            .deletingLastPathComponent() // TerminalApp/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Native/RelayStreamGuestFFI/Tests/Fixtures")
            .appendingPathComponent("ip_tunnel_network_settings_validator_v1.tsv")
    }

    /// Decode the table's explicit sentinels. `<empty>` is the empty string,
    /// `<sp>` is one space anywhere in the token, and any other `<...>` is a
    /// hard error rather than a value that quietly survives as literal text.
    private func decodeSession(_ raw: String) throws -> String {
        if raw == "<empty>" { return "" }
        var out = ""
        var rest = Substring(raw)
        while let start = rest.firstIndex(of: "<") {
            let close = try XCTUnwrap(
                rest[start...].firstIndex(of: ">"),
                "unterminated sentinel in \(raw)"
            )
            let token = String(rest[start...close])
            XCTAssertEqual(token, "<sp>", "unknown sentinel \(token) in \(raw)")
            out += rest[rest.startIndex..<start]
            out += " "
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    private func parseRows() throws -> [Row] {
        let url = tableURL()
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest,
            Self.tableDigest,
            "the parity table changed; update BOTH consumers in the same change"
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var sawTotal = false
        var sawCounts = false
        var sawHeader = false
        var orders: [(String, String)] = []
        var rows: [Row] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("@total\t") {
                XCTAssertEqual(String(line.dropFirst("@total\t".count)), Self.total)
                sawTotal = true
                continue
            }
            if line.hasPrefix("@counts\t") {
                XCTAssertEqual(String(line.dropFirst("@counts\t".count)), Self.counts)
                sawCounts = true
                continue
            }
            if line.hasPrefix("@order\t") {
                let body = String(line.dropFirst("@order\t".count))
                let parts = body.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                orders.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
                continue
            }
            if line == Self.header {
                sawHeader = true
                continue
            }
            XCTAssertTrue(sawHeader, "data row before the header: \(line)")

            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(cols.count, 11, "row must have 11 columns: \(line)")
            let appliesTo = cols[8]
            XCTAssertTrue(
                ["both", "rust_only", "swift_only"].contains(appliesTo),
                "unknown applies_to \(appliesTo)"
            )
            for verdict in [cols[9], cols[10]] {
                XCTAssertTrue(
                    ["accept", "reject", "n/a"].contains(verdict),
                    "unknown verdict \(verdict)"
                )
            }
            switch appliesTo {
            case "both":
                XCTAssertNotEqual(cols[9], "n/a", "both row lacks a rust verdict")
                XCTAssertNotEqual(cols[10], "n/a", "both row lacks a swift verdict")
            case "rust_only":
                XCTAssertEqual(cols[10], "n/a", "rust_only row must not verdict swift")
            default:
                XCTAssertEqual(cols[9], "n/a", "swift_only row must not verdict rust")
            }

            rows.append(
                Row(
                    caseID: cols[0],
                    addr: cols[1],
                    prefixLength: try XCTUnwrap(UInt8(cols[2])),
                    peer: cols[3],
                    settingsMTU: try XCTUnwrap(UInt16(cols[4])),
                    settingsSessionID: try decodeSession(cols[5]),
                    appliesTo: appliesTo,
                    swiftExpect: cols[10]
                )
            )
        }

        XCTAssertTrue(sawTotal && sawCounts && sawHeader, "table lost a directive")
        // Every category is declared, INCLUDING the empty one: an omitted
        // `swift_only` would read as "no Swift-only rules" when it actually
        // means the category vanished.
        XCTAssertEqual(orders.count, 3, "expected exactly three @order directives")
        let expected = [
            ("both", Self.orderBoth),
            ("rust_only", Self.orderRustOnly),
            ("swift_only", Self.orderSwiftOnly),
        ]
        for (index, pair) in expected.enumerated() {
            XCTAssertEqual(orders[index].0, pair.0, "@order category or order changed")
            XCTAssertEqual(orders[index].1, pair.1, "@order id list for \(pair.0) changed")
        }
        XCTAssertEqual(rows.count, 33, "table row count changed")
        XCTAssertEqual(Set(rows.map(\.caseID)).count, rows.count, "duplicate case_id")
        return rows
    }

    func testValidatorParityTableMatchesTheSwiftValidator() throws {
        let rows = try parseRows()
        var consumedBoth: [String] = []
        var consumedSwiftOnly: [String] = []

        for row in rows {
            switch row.appliesTo {
            case "both": consumedBoth.append(row.caseID)
            case "swift_only": consumedSwiftOnly.append(row.caseID)
            default: continue // rust_only is not this side's contract
            }

            let build = {
                try RelayStreamIPTunnelNetworkSettings.make(
                    assignment: RelayStreamIPv4Assignment(
                        address: row.addr,
                        prefixLength: row.prefixLength,
                        peer: row.peer
                    ),
                    mtu: row.settingsMTU,
                    sessionID: row.settingsSessionID
                )
            }
            if row.swiftExpect == "accept" {
                XCTAssertNoThrow(try build(), "row \(row.caseID) expected accept")
            } else {
                XCTAssertThrowsError(try build(), "row \(row.caseID) expected reject")
            }
        }

        XCTAssertEqual(
            consumedBoth.joined(separator: ","),
            Self.orderBoth,
            "the `both` rows consumed do not match the declaration"
        )
        XCTAssertEqual(
            consumedSwiftOnly.joined(separator: ","),
            Self.orderSwiftOnly,
            "the `swift_only` rows consumed do not match the declaration"
        )
    }
}
