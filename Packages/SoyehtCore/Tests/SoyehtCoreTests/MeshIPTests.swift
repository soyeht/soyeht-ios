import XCTest

@testable import SoyehtCore

final class MeshIPTests: XCTestCase {
    // Vectors pin sha256(normalize(network_id) + "\n" + pubkey_hex), followed
    // by `10.44.(d0 % 254 + 1).(d1 % 254 + 1)/32`.

    func testHexNetworkIDVectors() {
        XCTAssertEqual(
            MeshIP.deriveTunnelIP(networkId: "d6743db3", pubkeyHex: String(repeating: "ab", count: 32)),
            "10.44.57.238/32"
        )
        XCTAssertEqual(
            MeshIP.deriveTunnelIP(networkId: "d6743db3", pubkeyHex: String(repeating: "cd", count: 32)),
            "10.44.235.132/32"
        )
    }

    func testNonHexNetworkIDVector() {
        XCTAssertEqual(
            MeshIP.deriveTunnelIP(networkId: "example/claw_A", pubkeyHex: String(repeating: "11", count: 32)),
            "10.44.103.228/32"
        )
    }

    func testNormalizeHexLowercasesAndStripsSeparators() {
        XCTAssertEqual(MeshIP.normalizeRuntimeNetworkID(" D6-74-3D-B3 "), "d6743db3")
        XCTAssertEqual(MeshIP.normalizeRuntimeNetworkID("  example/claw_A  "), "example/claw_A")
    }

    func testNormalizedHexIDMatchesCompactForm() {
        let rendered = MeshIP.deriveTunnelIP(
            networkId: "D6-74-3D-B3",
            pubkeyHex: String(repeating: "ab", count: 32)
        )
        let compact = MeshIP.deriveTunnelIP(
            networkId: "d6743db3",
            pubkeyHex: String(repeating: "ab", count: 32)
        )

        XCTAssertEqual(rendered, compact)
        XCTAssertEqual(rendered, "10.44.57.238/32")
    }

    func testEmptyInputsReturnNil() {
        XCTAssertNil(MeshIP.deriveTunnelIP(networkId: "", pubkeyHex: "ab"))
        XCTAssertNil(MeshIP.deriveTunnelIP(networkId: "d6743db3", pubkeyHex: "  "))
    }
}
