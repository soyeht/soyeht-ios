import XCTest

@testable import SoyehtCore

/// PR-B (soyeht-ios side) — Swift half of the `GuestImageFailureCode` cross-language
/// contract. Validates the fixture vendored VERBATIM from theyos
/// (`admin/rust/core-rs/tests/fixtures/guest_image_failure_codes.json`) against the
/// Swift enum: every code's wire string is a known case, the set matches exactly,
/// and the iOS recovery action + CTA agree with the contract.
///
/// theyos owns `wire` + `default_scope`; this is the iOS validation of
/// `recovery_action` + `cta`. If the two ever diverge, that is a deliberate
/// cross-language change to be re-minted on BOTH sides — never patched silently here.
final class GuestImageFailureCodeFixtureTests: XCTestCase {

    private struct Contract: Decodable {
        let codes: [Row]
        struct Row: Decodable {
            let wire: String
            let defaultScope: String
            let recoveryAction: String
            let cta: String
        }
    }

    private func loadContract() throws -> Contract {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "guest_image_failure_codes", withExtension: "json"),
            "vendored guest_image_failure_codes.json missing from the test bundle"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Contract.self, from: Data(contentsOf: url))
    }

    /// Stable wire string for a recovery action (the iOS↔contract mapping). The
    /// exhaustive switch forces this to be updated if a new action is ever added.
    private func wire(_ action: GuestImageRecoveryAction) -> String {
        switch action {
        case .retry: return "retry"
        case .freeSpaceThenRetry: return "free_space_then_retry"
        case .restartMacRequired: return "restart_mac_required"
        case .openSoyehtOnMac: return "open_soyeht_on_mac"
        case .reinstallSoyehtOnMac: return "reinstall_soyeht_on_mac"
        case .none: return "none"
        }
    }

    private func wire(_ cta: GuestImageRecoveryCTA) -> String {
        switch cta {
        case .prepare: return "prepare"
        case .checkAgain: return "check_again"
        case .none: return "none"
        }
    }

    func test_fixtureMatchesSwiftRecoverySemantics() throws {
        let contract = try loadContract()

        // Every fixture wire is a known Swift case, and its recovery action + CTA
        // match the contract (catches a theyos code the Swift enum lacks, or drift).
        for row in contract.codes {
            guard let code = GuestImageFailureCode(rawValue: row.wire) else {
                XCTFail("fixture wire `\(row.wire)` has no GuestImageFailureCode case")
                continue
            }
            XCTAssertEqual(
                wire(code.recoveryAction), row.recoveryAction,
                "recovery_action mismatch for `\(row.wire)`"
            )
            XCTAssertEqual(
                wire(code.recoveryAction.cta), row.cta,
                "cta mismatch for `\(row.wire)`"
            )
        }

        // Bidirectional set parity: every Swift case is in the fixture and vice versa.
        let fixtureWires = Set(contract.codes.map(\.wire))
        for code in GuestImageFailureCode.allCases {
            XCTAssertTrue(
                fixtureWires.contains(code.rawValue),
                "Swift case \(code) (`\(code.rawValue)`) is missing from the vendored fixture"
            )
        }
        XCTAssertEqual(
            contract.codes.count, GuestImageFailureCode.allCases.count,
            "fixture code count != Swift case count"
        )
    }

    /// The load-bearing guarantee of this PR: `virtualization_unavailable` is terminal
    /// with NO mutating CTA — it must never resolve to `.prepare` / Try Again.
    func test_virtualizationUnavailable_isTerminalNeverPrepare() throws {
        let code = GuestImageFailureCode.virtualizationUnavailable
        XCTAssertEqual(code.recoveryAction, .none)
        XCTAssertEqual(code.recoveryAction.cta, GuestImageRecoveryCTA.none)
        XCTAssertNotEqual(code.recoveryAction.cta, .prepare, "must never offer a mutating Try Again")
        XCTAssertFalse(code.isUserRecoverableOnDevice)

        // …and the vendored contract agrees.
        let row = try XCTUnwrap(
            loadContract().codes.first { $0.wire == "virtualization_unavailable" }
        )
        XCTAssertEqual(row.recoveryAction, "none")
        XCTAssertEqual(row.cta, "none")
        XCTAssertEqual(row.defaultScope, "persistent")
    }
}
