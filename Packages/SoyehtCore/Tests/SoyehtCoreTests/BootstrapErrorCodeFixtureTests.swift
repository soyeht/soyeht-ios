import XCTest

@testable import SoyehtCore

/// Cross-language parity for `BootstrapErrorCode` ↔ the fixture vendored VERBATIM
/// from theyos household-rs (`bootstrap_error_codes.json`). Validates the bounded
/// set bidirectionally (every concrete code ⇄ every fixture row), decode is
/// fail-soft, and the legacy claim codes stay out of the typed set.
final class BootstrapErrorCodeFixtureTests: XCTestCase {

    private struct Contract: Decodable {
        let codes: [Row]
        struct Row: Decodable {
            let wire: String
            let httpStatus: Int
        }
    }

    private func loadContract() throws -> Contract {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "bootstrap_error_codes", withExtension: "json"),
            "vendored bootstrap_error_codes.json missing from the test bundle"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Contract.self, from: Data(contentsOf: url))
    }

    func test_fixtureMatchesSwiftEnumBidirectionally() throws {
        let contract = try loadContract()

        // Count parity: one fixture row per concrete (non-`.unknown`) code.
        XCTAssertEqual(
            contract.codes.count, BootstrapErrorCode.concrete.count,
            "fixture row count != concrete BootstrapErrorCode count"
        )

        // Every fixture wire is a known concrete code, round-trips, and has a status.
        for row in contract.codes {
            let code = BootstrapErrorCode(wire: row.wire)
            XCTAssertNotEqual(code, .unknown, "fixture wire `\(row.wire)` has no BootstrapErrorCode case")
            XCTAssertEqual(code.rawValue, row.wire, "round-trip mismatch for `\(row.wire)`")
            XCTAssertGreaterThanOrEqual(row.httpStatus, 100, "row `\(row.wire)` has an invalid http_status")
        }

        // Every concrete enum case appears in the fixture (bidirectional).
        let wires = Set(contract.codes.map(\.wire))
        for code in BootstrapErrorCode.concrete {
            XCTAssertTrue(
                wires.contains(code.rawValue),
                "enum code `\(code.rawValue)` is missing from the vendored fixture"
            )
        }
        // `.unknown` is receive-only: never a producer code in the fixture.
        XCTAssertFalse(wires.contains("unknown"))
    }

    func test_failSoftDecode() throws {
        XCTAssertEqual(BootstrapErrorCode(wire: "brand_new_future_code"), .unknown)
        XCTAssertEqual(BootstrapErrorCode(wire: ""), .unknown)
        let decoded = try JSONDecoder().decode(BootstrapErrorCode.self, from: Data("\"future_code\"".utf8))
        XCTAssertEqual(decoded, .unknown)
        // Concrete codes round-trip via Codable.
        for code in BootstrapErrorCode.concrete {
            let data = try JSONEncoder().encode(code)
            let back = try JSONDecoder().decode(BootstrapErrorCode.self, from: data)
            XCTAssertEqual(back, code)
        }
    }

    func test_legacyClaimCodesAreNotTypedAndNotInFixture() throws {
        // `invalid_state` / `already_named` are a legacy iOS expectation that
        // theyos@8effb506 no longer emits — they must stay `.unknown` and out of
        // the typed fixture set (SetupInvitationListener keeps them in a named
        // local allowlist, not in BootstrapErrorCode).
        let wires = Set(try loadContract().codes.map(\.wire))
        for legacy in ["invalid_state", "already_named"] {
            XCTAssertEqual(BootstrapErrorCode(wire: legacy), .unknown, "`\(legacy)` must not be a typed code")
            XCTAssertFalse(wires.contains(legacy), "`\(legacy)` must not be in the fixture")
        }
    }
}
