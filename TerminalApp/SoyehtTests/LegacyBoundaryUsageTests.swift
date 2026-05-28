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
/// 4. Household `ClawAPITarget` wire values appear only in
///    `ClawInstallTargetResolver.swift` (per `ClawRouteUsageTests`).
///    iOS UI may not hide that wire path behind a `?? .household`
///    fallback when constructing Claw ViewModels.
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
    /// `target: .household` / `target(.household` argument forms. This
    /// guard covers the fallback shape that used to exist in the Claw
    /// Store and Detail views when a `StateObject` required a raw
    /// `ClawAPITarget` before the `.unavailable` branch rendered.
    ///
    /// Those views now split into a public wrapper and a private resolved
    /// view: the wrapper renders unavailable UI before a ViewModel is
    /// constructed, and the resolved view requires `resolution.apiTarget`.
    /// A new `?? .household` site would therefore be a regression.
    func test_clawAPITargetHouseholdFallback_doesNotExistInIOSUI() throws {
        let offenders = try iosSwiftFiles().filter { url in
            if url.lastPathComponent == "LegacyBoundaryUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("?? .household")
        }
        XCTAssertTrue(offenders.isEmpty,
            "`?? .household` must not appear in iOS UI. Render unavailable Claw UI before constructing ViewModels, or funnel the household wire path through `ClawInstallTargetResolver`. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    // MARK: - Claw Setup architecture

    func test_clawSetupView_doesNotOwnRoutingOrResourcePolicy() throws {
        let url = try XCTUnwrap(iosSwiftFiles().first { $0.lastPathComponent == "ClawSetupView.swift" })
        let code = try codeOnly(at: url)

        XCTAssertFalse(code.contains("SessionStore.shared"),
            "ClawSetupView must receive deploy choices from ClawInstallTargetResolver, not SessionStore.shared."
        )
        XCTAssertFalse(code.contains("PairedMacsStore.shared"),
            "ClawSetupView must render server display metadata from the setup model, not PairedMacsStore.shared."
        )
        XCTAssertFalse(code.contains("live limits unavailable"),
            "ClawSetupView must not expose protocol/debug copy to users."
        )
        XCTAssertFalse(code.contains("ResourceOptions("),
            "ClawSetupView must not construct resource policy inputs."
        )
    }

    func test_clawSetupPerformanceSelector_ownsAccessibilitySelectionState() throws {
        let url = try XCTUnwrap(iosSwiftFiles().first { $0.lastPathComponent == "ClawSetupView.swift" })
        let code = try codeOnly(at: url)

        XCTAssertTrue(code.contains(".accessibilityElement(children: .ignore)"),
            "Performance profile buttons must ignore child SF Symbols so symbol labels like `checkmark.circle` cannot leak stale Selected traits."
        )
        XCTAssertTrue(code.contains(".accessibilityAddTraits(selected ? .isSelected : [])"),
            "Performance profile buttons must declare the selected accessibility trait from the actual view model state."
        )
        XCTAssertTrue(code.contains(".accessibilityHidden(true)"),
            "Performance profile icons are decorative; their SF Symbol accessibility labels must not drive button semantics."
        )
    }

    // MARK: - Claw installability gate (theyos #88)

    /// Installability is decided by the backend and surfaced as
    /// `Claw.installability` (SoyehtCore) — the single source of truth. iOS UI
    /// must consult it, never special-case a claw by name. A `claude-claw`
    /// literal in a view is the canonical regression: that is the exact claw
    /// the gate exists to suppress.
    func test_noClawNameLiteralsInIOSUI() throws {
        let offenders = try iosSwiftFiles().filter { url in
            if url.lastPathComponent == "LegacyBoundaryUsageTests.swift" { return false }
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("claude-claw")
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS UI must gate installability via `Claw.installability`, not by claw name. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    /// The UI must not re-derive installability from `tier` or from the raw
    /// reason-code wire strings. Those belong to the backend contract and to
    /// `ClawInstallability` in SoyehtCore; duplicating them in a view re-opens
    /// the drift the #88 gate closes.
    func test_noInstallabilityRuleDuplicationInIOSUI() throws {
        let forbidden = [".tier", "\"catalog_only\"", "\"detected_unverified\"", "\"no_install_plan\""]
        var offenders: [String] = []
        for url in try iosSwiftFiles() {
            if url.lastPathComponent == "LegacyBoundaryUsageTests.swift" { continue }
            let code = (try? codeOnly(at: url)) ?? ""
            for token in forbidden where code.contains(token) {
                offenders.append("\(url.lastPathComponent) [\(token)]")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "iOS UI must read `Claw.installability`, not tier/reason-code rules. Offenders: \(offenders)"
        )
    }

    /// Positive pin: the Claw Store views that render the Install CTA must
    /// consult `installability`. If a future refactor drops the gate, this
    /// fails loudly rather than silently re-showing Install for blocked claws.
    func test_clawStoreViewsConsultInstallability() throws {
        let required = ["ClawCardView.swift", "ClawDetailView.swift", "ClawStoreView.swift"]
        for name in required {
            let url = try XCTUnwrap(
                iosSwiftFiles().first { $0.lastPathComponent == name },
                "expected to find \(name)"
            )
            let code = try codeOnly(at: url)
            XCTAssertTrue(code.contains("installability"),
                "\(name) must gate the Install CTA on `Claw.installability` (theyos #88)."
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
