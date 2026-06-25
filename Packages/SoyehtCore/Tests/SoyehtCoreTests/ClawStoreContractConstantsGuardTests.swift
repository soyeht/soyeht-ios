import Testing
import Foundation

/// Drift guard for the generated `ClawStoreContractConstants`. The generated file
/// is a pure function of the vendored Claw Store contract; this test re-derives
/// the route-id / auth-kind / household-operation sets straight from
/// `contract.json` and asserts the generated constants match. If a synced contract
/// adds/removes/renames any of them, this fails until the generator is re-run:
///   uv run python scripts/gen-claw-store-contract-constants.py
///
/// (The exact-route-id LOCKSTEP gate stays in `ClawStoreContractFixtureTests`; it
/// is a deliberate human checkpoint and is intentionally NOT replaced by this.)
@Suite struct ClawStoreContractConstantsGuardTests {

    private struct Contract {
        let ids: Set<String>
        let authKinds: Set<String>
        let operations: Set<String>
    }

    private func loadContract() throws -> Contract {
        let url = try #require(Bundle.module.url(
            forResource: "contract",
            withExtension: "json",
            subdirectory: "Fixtures/claw-store/v1"
        ))
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routes = try #require(object["routes"] as? [[String: Any]])
        return Contract(
            ids: Set(routes.compactMap { $0["id"] as? String }),
            authKinds: Set(routes.compactMap { $0["auth_kind"] as? String }),
            operations: Set(routes.compactMap { $0["household_operation"] as? String })
        )
    }

    @Test func generatedRouteIDsMatchContract() throws {
        let contract = try loadContract()
        #expect(
            Set(ClawStoreContractConstants.RouteID.all) == contract.ids,
            "Generated route IDs are stale vs the contract. Run: uv run python scripts/gen-claw-store-contract-constants.py"
        )
    }

    @Test func generatedAuthKindsMatchContract() throws {
        let contract = try loadContract()
        #expect(
            Set(ClawStoreContractConstants.AuthKind.all) == contract.authKinds,
            "Generated auth kinds are stale vs the contract. Run: uv run python scripts/gen-claw-store-contract-constants.py"
        )
    }

    @Test func generatedHouseholdOperationsMatchContract() throws {
        let contract = try loadContract()
        #expect(
            Set(ClawStoreContractConstants.HouseholdOperation.all) == contract.operations,
            "Generated household operations are stale vs the contract. Run: uv run python scripts/gen-claw-store-contract-constants.py"
        )
    }

    /// The generated constants must have no accidental duplicates (the generator
    /// derives them from a Set, so counts must equal the de-duplicated counts).
    @Test func generatedConstantsHaveNoDuplicates() {
        #expect(ClawStoreContractConstants.RouteID.all.count == Set(ClawStoreContractConstants.RouteID.all).count)
        #expect(ClawStoreContractConstants.AuthKind.all.count == Set(ClawStoreContractConstants.AuthKind.all).count)
        #expect(ClawStoreContractConstants.HouseholdOperation.all.count == Set(ClawStoreContractConstants.HouseholdOperation.all).count)
    }
}
