import XCTest

/// PR-3 source-slice tests. The iOS Claw Store must never construct
/// `.householdStore` or `.householdDetail` routes (those exist only for
/// macOS), and household `ClawAPITarget` routing may appear in exactly
/// one iOS file — `ClawInstallTargetResolver.swift`. Other appearances
/// mean someone bypassed the resolver.
///
/// These tests walk the file tree at compile-time-known paths derived
/// from `#filePath`. They are intentionally string-grep tests: catching
/// the violation early is more valuable than parsing Swift.
final class ClawRouteUsageTests: XCTestCase {

    func test_iosUI_neverConstructsHouseholdStoreRoute() throws {
        let offenders = try iosSwiftFiles().filter { url in
            // Skip this test file (the literals self-trip).
            if url.lastPathComponent == "ClawRouteUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            // Be specific: only flag concrete *construction* of the
            // case. The exhaustive `switch route` ramps reference the
            // case but don't *push* it — exclude by requiring the
            // `.append(...)` shape (the only way to construct a route
            // in this codebase) OR the bare `ClawRoute.householdStore`
            // literal in code context.
            return code.contains(".append(ClawRoute.householdStore)")
                || code.contains(".append(.householdStore)")
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS UI must not construct `.householdStore` routes. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    func test_iosUI_neverConstructsHouseholdDetailRoute() throws {
        let offenders = try iosSwiftFiles().filter { url in
            if url.lastPathComponent == "ClawRouteUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains(".append(ClawRoute.householdDetail(")
                || code.contains(".append(.householdDetail(")
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS UI must not construct `.householdDetail` routes. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    /// Returns the file at `url` with comment-only lines stripped, so
    /// doc-comment mentions of forbidden symbols don't trip code-only
    /// invariants.
    private func codeOnly(at url: URL) throws -> String {
        SourceCommentStripper.strip(try String(contentsOf: url, encoding: .utf8))
    }

    func test_ClawAPITargetHousehold_onlyAppearsInResolver() throws {
        let offenders = try iosSwiftFiles().filter { url in
            // Exempt the resolver itself — that's the one approved
            // place. Also exempt this test file (literals would
            // self-trip).
            let name = url.lastPathComponent
            if name == "ClawInstallTargetResolver.swift" { return false }
            if name == "ClawRouteUsageTests.swift" { return false }
            if name == "ClawInstallTargetResolverTests.swift" { return false }

            // Comment-stripped code only, so doc-comment mentions of the symbol
            // (e.g. the file-header doc on `ClawInstallTarget.swift`) don't trip
            // the test. Shared with the other guards via `SourceCommentStripper`.
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("ClawAPITarget.household")
                || code.contains("ClawAPITarget.householdEndpoint")
                || code.contains("target: .household")
                || code.contains("target: .householdEndpoint")
                || code.contains("target(.household")
                || code.contains("target(.householdEndpoint")
        }
        XCTAssertTrue(offenders.isEmpty,
            "Household `ClawAPITarget` routing may appear only in `ClawInstallTargetResolver.swift`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    /// E2d-4: the Store view model is built from the canonical `ClawMachineTarget`
    /// (which carries the serverID), never from the lossy `ClawAPITarget`
    /// (`resolution.apiTarget` drops the serverID on `.householdEndpoint`). Pin
    /// the boundary so it can't silently regress.
    func test_clawStoreViewModel_builtFromMachineTarget_notLossyApiTarget() throws {
        let offenders = try iosSwiftFiles().filter { url in
            if url.lastPathComponent == "ClawRouteUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("ClawStoreViewModel(target:")
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS UI must build `ClawStoreViewModel` from a `ClawMachineTarget` (machineTarget:), not the lossy `ClawAPITarget`. Offending: \(offenders.map(\.lastPathComponent))"
        )

        let storeView = try iosSwiftFiles().first { $0.lastPathComponent == "ClawStoreView.swift" }
        let storeCode = try storeView.map { try codeOnly(at: $0) } ?? ""
        XCTAssertTrue(storeCode.contains("ClawStoreViewModel(machineTarget:"),
            "ResolvedClawStoreView must construct `ClawStoreViewModel(machineTarget: resolution)`."
        )
    }

    // MARK: - Helpers

    private func iosSwiftFiles() throws -> [URL] {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let soyehtRoot = terminalApp.appendingPathComponent("Soyeht")

        let enumerator = FileManager.default.enumerator(
            at: soyehtRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }
}
