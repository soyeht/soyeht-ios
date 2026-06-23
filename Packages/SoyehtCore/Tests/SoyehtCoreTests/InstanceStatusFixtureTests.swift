import XCTest

@testable import SoyehtCore

/// Cross-language parity for `InstanceStatus` ↔ the fixture vendored VERBATIM from
/// theyos store-rs (`instance_status_codes.json` — the EMITTED wire set). Validates
/// the bounded set bidirectionally, the fail-soft decode, and that the legacy
/// `error` alias + the `running` (DesiredState, not lifecycle) value are NOT part of
/// the emitted contract.
final class InstanceStatusFixtureTests: XCTestCase {

    private struct Contract: Decodable {
        let statuses: [Row]
        struct Row: Decodable { let wire: String }
    }

    private func loadContract() throws -> Contract {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "instance_status_codes", withExtension: "json"),
            "vendored instance_status_codes.json missing from the test bundle"
        )
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    func test_fixtureMatchesEnumBidirectionally() throws {
        let contract = try loadContract()

        XCTAssertEqual(
            contract.statuses.count, InstanceStatus.concrete.count,
            "fixture count != concrete InstanceStatus count"
        )

        let wires = Set(contract.statuses.map(\.wire))
        for row in contract.statuses {
            let status = InstanceStatus(wire: row.wire)
            XCTAssertNotEqual(status, .unknown, "fixture wire `\(row.wire)` is not a known InstanceStatus")
            XCTAssertEqual(status.rawValue, row.wire, "round-trip mismatch for `\(row.wire)`")
        }
        for status in InstanceStatus.concrete {
            XCTAssertTrue(
                wires.contains(status.rawValue),
                "enum status `\(status.rawValue)` is missing from the vendored fixture"
            )
        }
        // Neither `.unknown`, the legacy `error` alias, nor `running` (DesiredState)
        // are emitted-contract values.
        XCTAssertFalse(wires.contains("unknown"))
        XCTAssertFalse(wires.contains("error"))
        XCTAssertFalse(wires.contains("running"))
    }

    func test_failSoftDecodeAndLegacyErrorAlias() throws {
        // Legacy receive-only alias (mirrors theyos FromStr) — not in the fixture.
        XCTAssertEqual(InstanceStatus(wire: "error"), .failed)
        // `running` is DesiredState, never emitted as `status` → fail-soft `.unknown`.
        XCTAssertEqual(InstanceStatus(wire: "running"), .unknown)
        XCTAssertEqual(InstanceStatus(wire: "future_status"), .unknown)
        XCTAssertEqual(InstanceStatus(wire: ""), .unknown)

        // Codable decode is fail-soft (incl. the alias) and concrete codes round-trip.
        XCTAssertEqual(try JSONDecoder().decode(InstanceStatus.self, from: Data("\"error\"".utf8)), .failed)
        XCTAssertEqual(try JSONDecoder().decode(InstanceStatus.self, from: Data("\"draining\"".utf8)), .unknown)
        for status in InstanceStatus.concrete {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(InstanceStatus.self, from: data), status)
        }
    }
}
