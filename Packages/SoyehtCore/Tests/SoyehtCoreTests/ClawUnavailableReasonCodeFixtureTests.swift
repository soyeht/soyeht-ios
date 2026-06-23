import XCTest

@testable import SoyehtCore

/// Cross-language parity for `ClawUnavailableReasonCode` <-> the fixture vendored
/// VERBATIM from theyos core-rs (`claw_unavailable_reason_codes.json` -- the EMITTED
/// wire set for `core_rs::manifest::UnavailableReasonCode`). Validates the bounded
/// set bidirectionally and the fail-soft `.unknown` decode (a receive-only fallback
/// that is NOT an emitted-contract wire).
final class ClawUnavailableReasonCodeFixtureTests: XCTestCase {

    /// The concrete (emitted) reason codes. `.unknown` is a receive-only fail-soft
    /// fallback, never emitted, so it is excluded from the contract set.
    private static let concrete: [ClawUnavailableReasonCode] = [
        .catalogOnly, .detectedUnverified, .noInstallPlan,
    ]

    private struct Contract: Decodable {
        let codes: [Row]
        struct Row: Decodable { let wire: String }
    }

    private func loadContract() throws -> Contract {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "claw_unavailable_reason_codes", withExtension: "json"),
            "vendored claw_unavailable_reason_codes.json missing from the test bundle"
        )
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    func test_fixtureMatchesEnumBidirectionally() throws {
        let contract = try loadContract()

        XCTAssertEqual(
            contract.codes.count, Self.concrete.count,
            "fixture count != concrete ClawUnavailableReasonCode count"
        )

        let wires = Set(contract.codes.map(\.wire))
        for row in contract.codes {
            let code = ClawUnavailableReasonCode(rawValue: row.wire)
            XCTAssertNotNil(code, "fixture wire `\(row.wire)` is not a known ClawUnavailableReasonCode")
            XCTAssertNotEqual(code, .unknown, "fixture wire `\(row.wire)` must be a concrete code, not .unknown")
            XCTAssertEqual(code?.rawValue, row.wire, "round-trip mismatch for `\(row.wire)`")
        }
        for code in Self.concrete {
            XCTAssertTrue(
                wires.contains(code.rawValue),
                "enum code `\(code.rawValue)` is missing from the vendored fixture"
            )
        }
        // `.unknown` is a receive-only fail-soft fallback, never an emitted wire.
        XCTAssertFalse(wires.contains("unknown"))
    }

    func test_failSoftReceiveOnlyUnknown() throws {
        // A new / unrecognized backend value decodes fail-soft to `.unknown`.
        XCTAssertEqual(
            try JSONDecoder().decode(
                ClawUnavailableReasonCode.self, from: Data("\"platform_unsupported\"".utf8)
            ),
            .unknown
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ClawUnavailableReasonCode.self, from: Data("\"\"".utf8)),
            .unknown
        )
        // The concrete codes round-trip through Codable.
        for code in Self.concrete {
            let data = try JSONEncoder().encode(code)
            XCTAssertEqual(try JSONDecoder().decode(ClawUnavailableReasonCode.self, from: data), code)
        }
        // A future value has no rawValue; the decoder maps it to `.unknown`.
        XCTAssertNil(ClawUnavailableReasonCode(rawValue: "platform_unsupported"))
    }
}
