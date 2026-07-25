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
