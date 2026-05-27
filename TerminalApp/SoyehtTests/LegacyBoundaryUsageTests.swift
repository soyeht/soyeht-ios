import XCTest

/// Source-slice tests pinning the iOS legacy-boundary rules established by
/// PR-1 (`SoyehtIdentity`), PR-2 (`ServerRegistry`), and PR-3
/// (`ClawInstallTarget`). The legacy storage types
/// (`HouseholdSessionStore`, `ActiveHouseholdState`, `PairedMacsStore`,
/// `SessionStore`) remain alive on purpose — they hold the keychain /
/// UserDefaults state and the protocol-level wire types. What this file
/// enforces is that **new iOS UI code does not reach into them
/// directly**; it must go through the facades.
///
/// The rules tested here, restated as English contracts:
///
/// 1. `SessionStore.shared.pairedServers` is read only inside the
///    `ServerRegistry` mirror and the startup migration in
///    `AppDelegate`. New UI must use `ServerRegistry.shared`.
/// 2. `PairedMacsStore.shared.macs` (the list/collection accessor) is
///    read only inside the `ServerRegistry` facade and its observable
///    wrapper. Per-device identifiers (`deviceID`, `deviceName`,
///    `deviceModel`) are not in scope here — those are not "list of
///    paired Macs" and are read by anything that needs to identify
///    *this* iPhone.
/// 3. `HouseholdSessionStore()` is constructed only by the
///    `SoyehtIdentity` facade, the internal `HouseholdSessionController`
///    adapter, and the `Household/*` orchestrators that own the
///    protocol layer. UI reads identity through `SoyehtIdentity.shared`.
/// 4. `ClawAPITarget.household` as a wire value appears only in
///    `ClawInstallTargetResolver.swift` (per `ClawRouteUsageTests`)
///    plus the single documented `?? .household` fallback in
///    `ClawStoreView.swift`. A second fallback would be a hidden
///    re-introduction of the household wire path and is blocked here.
///
/// `.householdStore` / `.householdDetail` construction rules are
/// covered by `ClawRouteUsageTests`; this file does not duplicate them.
final class LegacyBoundaryUsageTests: XCTestCase {

    // MARK: - SessionStore.pairedServers

    func test_sessionStorePairedServers_onlyInBoundaryFiles() throws {
        // Each allowlist entry must carry a one-liner justifying why
        // the file is allowed to bypass `ServerRegistry.shared`. New
        // entries require a doc update in `docs/architecture.md`.
        let allowed: [String: String] = [
            // The facade itself + the legacy mirror that turns the two
            // stores into a single `servers` array.
            "ServerRegistry.swift": "the facade",
            // One-shot startup migration: builds the seed for
            // `ServerRegistry.shared.migrateLegacy`.
            "AppDelegate.swift": "startup migration seed",
        ]
        let offenders = try iosSwiftFiles().filter { url in
            let name = url.lastPathComponent
            if name == "LegacyBoundaryUsageTests.swift" { return false }
            if allowed.keys.contains(name) { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            // Catch both `SessionStore.shared.pairedServers` and the
            // `store.pairedServers` shape where `store` is a local
            // alias for `SessionStore.shared`. The bare token
            // `.pairedServers` is specific enough — there is no other
            // type in this codebase with that property name.
            return code.contains(".pairedServers")
        }
        XCTAssertTrue(offenders.isEmpty,
            "New iOS UI must read paired servers through `ServerRegistry.shared`, not `SessionStore.pairedServers`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    // MARK: - PairedMacsStore.shared.macs

    func test_pairedMacsStoreMacs_onlyInBoundaryFiles() throws {
        let allowed: [String: String] = [
            // The facade. `pairedMac(for:)` and the legacy mirror both
            // read `PairedMacsStore.shared.macs` to bridge to `Server`.
            "ServerRegistry.swift": "the facade",
            // The Combine-friendly mirror — needs `.macs` to seed
            // `@Published var macs` and refresh on `onChange`.
            "PairedMacsStoreObservable.swift": "@Published mirror",
            // Startup migration seed (same as the `pairedServers`
            // boundary above).
            "AppDelegate.swift": "startup migration seed",
        ]
        let offenders = try iosSwiftFiles().filter { url in
            let name = url.lastPathComponent
            if name == "LegacyBoundaryUsageTests.swift" { return false }
            if allowed.keys.contains(name) { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            // `.macs` on the store specifically. `PairedMacRegistry`
            // and other types use different property names so this is
            // unambiguous in this codebase.
            return code.contains("PairedMacsStore.shared.macs")
        }
        XCTAssertTrue(offenders.isEmpty,
            "New iOS UI must read the paired-Mac list through `ServerRegistry.shared.macs`, not `PairedMacsStore.shared.macs`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    // MARK: - HouseholdSessionStore()

    func test_householdSessionStoreConstruction_onlyInBoundaryFiles() throws {
        let allowed: [String: String] = [
            // The facade boundary — `SoyehtIdentity.shared` reads from
            // exactly this store and exposes the state machine.
            "SoyehtIdentity.swift": "the facade",
            // Internal adapter that wraps `HouseholdSessionStore` with
            // an observable refresh hop.
            "HouseholdSessionController.swift": "internal adapter",
            // `Household/*` orchestrator: pair flow that writes the
            // freshly-paired state into the keychain.
            "HouseholdPairingViewModel.swift": "Household/* orchestrator (pair write)",
            // `Household/*` orchestrator: APNS suspend/resume needs
            // the household id at protocol level.
            "APNSRegistrationCoordinator.swift": "Household/* orchestrator (APNS)",
        ]
        let offenders = try iosSwiftFiles().filter { url in
            let name = url.lastPathComponent
            if name == "LegacyBoundaryUsageTests.swift" { return false }
            if allowed.keys.contains(name) { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("HouseholdSessionStore()")
        }
        XCTAssertTrue(offenders.isEmpty,
            "New iOS UI must use `SoyehtIdentity.shared` rather than constructing a fresh `HouseholdSessionStore()`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    // MARK: - ClawInstallTarget routing

    /// The iOS Claw Store always presents `ClawStoreView` with a
    /// `ClawInstallTarget` — never with a raw `ClawAPITarget`. PR-3
    /// established that boundary; this test pins it.
    func test_clawStoreView_isAlwaysConstructedWithInstallTarget() throws {
        let offenders = try iosSwiftFiles().filter { url in
            if url.lastPathComponent == "LegacyBoundaryUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            // Forbid the legacy initializer shape: `ClawStoreView(target:`.
            // The only allowed init is `ClawStoreView(installTarget:)`,
            // which the test for `ClawAPITarget.household` (in
            // `ClawRouteUsageTests`) defends from the other direction.
            return code.contains("ClawStoreView(target:")
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS Claw Store views must be constructed with `installTarget:`. The `target:` form bypasses `ClawInstallTargetResolver`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    // MARK: - ClawAPITarget.household fallback

    /// `ClawRouteUsageTests.test_ClawAPITargetHousehold_onlyAppearsInResolver`
    /// catches the dotted `ClawAPITarget.household` form and the
    /// `target: .household` / `target(.household` argument forms. It
    /// does NOT catch the `?? .household` fallback shape, which exists
    /// today in exactly two iOS UI sites:
    ///
    /// - `ClawStoreView.swift` — fallback for `ClawStoreViewModel.target`
    ///   when the resolution is `.unavailable` and the body renders
    ///   `MacClawUnavailableView`.
    /// - `ClawDetailView.swift` — the parallel fallback for
    ///   `ClawDetailViewModel.target`, same justification.
    ///
    /// Both fallbacks are documented in-file and the StateObject they
    /// feed is never asked to hit the network in the `.unavailable`
    /// path. This test pins those as the **only** allowed sites — a
    /// third file growing a `?? .household` would re-introduce the
    /// household wire path through the back door. The TODO to collapse
    /// both fallbacks (by making the ViewModel target optional)
    /// lives in `docs/architecture.md`.
    func test_clawAPITargetHouseholdFallback_onlyInDocumentedSites() throws {
        let allowed: [String: String] = [
            // Documented fallback. See `ClawStoreView.init(installTarget:)`
            // and the TODO in `docs/architecture.md`.
            "ClawStoreView.swift": "documented `?? .household` fallback for the catalog ViewModel",
            // Parallel fallback created by PR-3 for the detail view —
            // same shape, same `.unavailable` justification.
            "ClawDetailView.swift": "documented `?? .household` fallback for the detail ViewModel",
        ]
        let offenders = try iosSwiftFiles().filter { url in
            let name = url.lastPathComponent
            if name == "LegacyBoundaryUsageTests.swift" { return false }
            if allowed.keys.contains(name) { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("?? .household")
        }
        XCTAssertTrue(offenders.isEmpty,
            "`?? .household` is only allowed in the documented Claw Store/Detail fallbacks. A new fallback site re-introduces the household wire path. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    /// Belt-and-braces: even inside the two allowed files, only one
    /// `?? .household` may exist per file. A second occurrence — even
    /// at a different line in the same file — is a hidden
    /// re-introduction (e.g. a copy-pasted helper).
    func test_documentedHouseholdFallbacks_haveExactlyOneOccurrenceEach() throws {
        let expected = [
            "ClawStoreView.swift",
            "ClawDetailView.swift",
        ]
        let files = try iosSwiftFiles()
        for name in expected {
            let url = try XCTUnwrap(files.first { $0.lastPathComponent == name },
                "\(name) not found under TerminalApp/Soyeht/ — file moved or renamed? Update the allowlist."
            )
            let code = try codeOnly(at: url)
            // `components(separatedBy:).count - 1` is the standard
            // occurrence-count idiom.
            let count = code.components(separatedBy: "?? .household").count - 1
            XCTAssertEqual(count, 1,
                "\(name) must hold exactly one `?? .household` fallback. Found \(count). A second one is a regression — see the TODO in docs/architecture.md."
            )
        }
    }

    // MARK: - Helpers

    /// Returns the file at `url` with comment-only lines stripped, so
    /// doc-comment mentions of forbidden symbols don't trip code-only
    /// invariants. Same heuristic as `ClawRouteUsageTests`.
    private func codeOnly(at url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }

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
