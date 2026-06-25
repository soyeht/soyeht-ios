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

    // MARK: - Guest-image recovery: reason codes, no raw daemon strings as primary

    /// Scoped to the guest-image recovery surfaces ONLY (so legitimate
    /// `localizedDescription` use elsewhere is untouched). Enforces PR-C:
    ///   - the two recovery views render via `GuestImageFailureCopy` (reason-coded)
    ///     and keep raw engine text behind a `DisclosureGroup` ("Details"),
    ///   - the gate no longer falls through to `error.localizedDescription`.
    func test_guestImageRecovery_isReasonCoded_noRawStringPrimary() throws {
        let viewNames = ["ClawDetailView.swift", "ClawStoreView.swift"]
        let gateName = "GuestImageReadinessGate.swift"

        let views = try iosSwiftFiles().filter { viewNames.contains($0.lastPathComponent) }
        XCTAssertEqual(
            Set(views.map(\.lastPathComponent)), Set(viewNames),
            "Expected to locate both guest-image recovery views."
        )
        for url in views {
            let code = (try? codeOnly(at: url)) ?? ""
            XCTAssertTrue(
                code.contains("GuestImageFailureCopy"),
                "\(url.lastPathComponent) must render guest-image failures via GuestImageFailureCopy (reason-coded copy)."
            )
            XCTAssertTrue(
                code.contains("DisclosureGroup"),
                "\(url.lastPathComponent) must keep the raw engine error behind a Details disclosure, not as a primary line."
            )
        }

        guard let gate = try iosSwiftFiles().first(where: { $0.lastPathComponent == gateName }) else {
            return XCTFail("Expected to locate \(gateName).")
        }
        let gateCode = (try? codeOnly(at: gate)) ?? ""
        XCTAssertFalse(
            gateCode.contains("error.localizedDescription"),
            "\(gateName) must not surface raw `error.localizedDescription` — the prepare-error path uses a localized generic; reason copy comes from the failure code."
        )
    }

    /// Mac sibling of `test_guestImageRecovery_isReasonCoded_noRawStringPrimary`,
    /// enforced on `TerminalApp/SoyehtMac/`. The Mac Claw Store recovery surfaces
    /// must render reason-coded copy through `MacGuestImageRecovery` (the SSOT
    /// keyed off `GuestImageFailureCode`) rather than raw daemon/VZ strings or a
    /// re-implemented failure-code switch.
    ///
    /// Scoped deliberately to the recovery surfaces. `ClawDrawerViewController`'s
    /// general install/action error path is intentionally out of scope here (its
    /// `error.localizedDescription` is a generic error display, not the
    /// guest-image recovery banner) — tracked separately if it warrants a guard.
    func test_macGuestImageRecovery_isReasonCoded_noRawStringPrimary() throws {
        let viewNames = ["MacClawStoreRootView.swift", "MacClawDetailView.swift"]
        let gateName = "MacGuestImageReadinessGate.swift"
        let policyName = "MacGuestImageRecovery.swift"

        let macFiles = try macSwiftFiles()

        let views = macFiles.filter { viewNames.contains($0.lastPathComponent) }
        XCTAssertEqual(
            Set(views.map(\.lastPathComponent)), Set(viewNames),
            "Expected to locate both Mac guest-image recovery views."
        )
        // Raw `GuestImageFailureCode` cases that must never appear in a view — the
        // failure-code → copy/CTA switch is owned solely by `MacGuestImageRecovery`
        // (the SSOT). `.unknown` is deliberately excluded: `MacClawDetailView` uses
        // `case .unknown` for an unrelated install-state banner, so matching it here
        // would be a false positive; the specific codes below are sufficient to
        // catch a re-implemented recovery switch.
        let forbiddenFailureCases = [
            "case .hostVmLimitReached",
            "case .helperMissing",
            "case .insufficientDisk",
            "case .entitlementMissing",
            "case .ipswDownloadFailed",
            "case .ipswIncompatible",
            "case .virtualizationUnavailable",
        ]
        for url in views {
            let code = (try? codeOnly(at: url)) ?? ""
            XCTAssertTrue(
                code.contains("MacGuestImageRecoveryBanner"),
                "\(url.lastPathComponent) must render guest-image failures via MacGuestImageRecoveryBanner (reason-coded copy from MacGuestImageRecovery)."
            )
            for raw in forbiddenFailureCases {
                XCTAssertFalse(
                    code.contains(raw),
                    "\(url.lastPathComponent) must not re-implement recovery copy/CTA via a raw GuestImageFailureCode switch (`\(raw)`) — the SSOT is MacGuestImageRecovery."
                )
            }
            XCTAssertFalse(
                code.contains("error.localizedDescription"),
                "\(url.lastPathComponent) must not surface a raw engine error as primary recovery copy."
            )
        }

        guard let gate = macFiles.first(where: { $0.lastPathComponent == gateName }) else {
            return XCTFail("Expected to locate \(gateName).")
        }
        XCTAssertFalse(
            ((try? codeOnly(at: gate)) ?? "").contains("error.localizedDescription"),
            "\(gateName) must not surface raw `error.localizedDescription` — reason copy comes from GuestImageFailureCode via MacGuestImageRecovery."
        )

        guard let policy = macFiles.first(where: { $0.lastPathComponent == policyName }) else {
            return XCTFail("Expected to locate \(policyName).")
        }
        let policyCode = (try? codeOnly(at: policy)) ?? ""
        for required in ["GuestImageFailureCode", "GuestImageRecoveryPolicy.presentation", "presentation.cta"] {
            XCTAssertTrue(
                policyCode.contains(required),
                "\(policyName) must remain the reason-coded SSOT: copy derives from GuestImageFailureCode and the CTA from the shared GuestImageRecoveryPolicy (`\(required)`), not duplicated rules."
            )
        }
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

    /// The iOS catalog install surfaces (card + store) must derive install/retry
    /// from the shared `ClawActionPolicy`, not re-derive the rule inline. Scoped to
    /// ClawCardView/ClawStoreView only; the detail view uses
    /// `ClawDetailActionAvailability` and is out of this guard's scope.
    private let iosCatalogInstallSurfaces = ["ClawCardView.swift", "ClawStoreView.swift"]

    func test_iosCatalogInstallSurfacesUseActionPolicy() throws {
        for name in iosCatalogInstallSurfaces {
            let url = try XCTUnwrap(
                iosSwiftFiles().first { $0.lastPathComponent == name },
                "expected to find \(name)"
            )
            let code = try codeOnly(at: url)
            XCTAssertTrue(code.contains("ClawActionPolicy"),
                "\(name) must derive its install/retry CTA from the shared ClawActionPolicy, not inline."
            )
        }
    }

    /// Companion guard: those two catalog surfaces must NOT re-derive installability
    /// inline (`installability.isInstallable`) - that rule now lives in
    /// `ClawActionPolicy`. The `installability:` token still appears (passed into
    /// the policy input), so `test_clawStoreViewsConsultInstallability` stays green.
    func test_iosCatalogDoesNotReDeriveInstallabilityInline() throws {
        for name in iosCatalogInstallSurfaces {
            let url = try XCTUnwrap(
                iosSwiftFiles().first { $0.lastPathComponent == name },
                "expected to find \(name)"
            )
            let code = try codeOnly(at: url)
            XCTAssertFalse(code.contains("installability.isInstallable"),
                "\(name) must not re-derive installability inline; route install/retry through ClawActionPolicy (which owns the isInstallable rule)."
            )
        }
    }

    // MARK: - Claw installability gate — macOS surface (theyos #88)

    /// Same SSOT rule as the iPhone guards, enforced on `TerminalApp/SoyehtMac/`.
    /// The Mac Claw Store has its own views (`MacClawCardView`,
    /// `MacClawDetailView`, `ClawDrawerViewController`) — they must gate the
    /// Install CTA on `Claw.installability`, never by claw name.
    func test_noClawNameLiteralsInMacUI() throws {
        let offenders = try macSwiftFiles().filter { url in
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains("claude-claw")
        }
        XCTAssertTrue(offenders.isEmpty,
            "Mac UI must gate installability via `Claw.installability`, not by claw name. Offending files: \(offenders.map(\.lastPathComponent))"
        )
    }

    func test_noInstallabilityRuleDuplicationInMacUI() throws {
        let forbidden = [".tier", "\"catalog_only\"", "\"detected_unverified\"", "\"no_install_plan\""]
        var offenders: [String] = []
        for url in try macSwiftFiles() {
            let code = (try? codeOnly(at: url)) ?? ""
            for token in forbidden where code.contains(token) {
                offenders.append("\(url.lastPathComponent) [\(token)]")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Mac UI must read `Claw.installability`, not tier/reason-code rules. Offenders: \(offenders)"
        )
    }

    /// Positive pin: the Mac surfaces that can trigger an install must consult
    /// `installability`. `ClawDrawerViewController` is included specifically
    /// because it calls `apiClient.installClaw` directly (not via the shared
    /// ViewModel), so its own guard is the only thing standing between a
    /// non-installable claw and a doomed request.
    func test_macClawSurfacesConsultInstallability() throws {
        let required = ["MacClawCardView.swift", "MacClawDetailView.swift", "ClawDrawerViewController.swift"]
        for name in required {
            let url = try XCTUnwrap(
                macSwiftFiles().first { $0.lastPathComponent == name },
                "expected to find \(name)"
            )
            let code = try codeOnly(at: url)
            XCTAssertTrue(code.contains("installability"),
                "\(name) must gate the Install CTA on `Claw.installability` (theyos #88)."
            )
        }
    }

    /// Goal D: detail screens may render native controls, but install/retry/
    /// deploy/uninstall policy must be shared in SoyehtCore instead of
    /// re-derived independently by the iOS and macOS detail views.
    func test_clawDetailViewsUseSharedActionAvailabilityPolicy() throws {
        let iosDetail = try XCTUnwrap(
            iosSwiftFiles().first { $0.lastPathComponent == "ClawDetailView.swift" },
            "expected iOS ClawDetailView.swift"
        )
        let macDetail = try XCTUnwrap(
            macSwiftFiles().first { $0.lastPathComponent == "MacClawDetailView.swift" },
            "expected macOS MacClawDetailView.swift"
        )

        XCTAssertTrue(try codeOnly(at: iosDetail).contains("ClawDetailActionAvailability("))
        XCTAssertTrue(try codeOnly(at: macDetail).contains("ClawDetailActionAvailability("))
    }

    /// In-flight enablement for the detail action buttons must come from the shared
    /// `ClawActionPolicy` (policy.isEnabled), not a hand-rolled
    /// `.disabled(viewModel.isPerformingAction)` re-derived per button. The facade
    /// above still owns visibility; the policy owns the in-flight enablement axis.
    func test_clawDetailViewsRouteInFlightEnablementThroughPolicy() throws {
        let iosDetail = try XCTUnwrap(
            iosSwiftFiles().first { $0.lastPathComponent == "ClawDetailView.swift" },
            "expected iOS ClawDetailView.swift"
        )
        let macDetail = try XCTUnwrap(
            macSwiftFiles().first { $0.lastPathComponent == "MacClawDetailView.swift" },
            "expected macOS MacClawDetailView.swift"
        )
        for url in [iosDetail, macDetail] {
            let code = try codeOnly(at: url)
            XCTAssertTrue(code.contains("ClawActionPolicy"),
                "\(url.lastPathComponent) must drive action enablement through the shared ClawActionPolicy."
            )
            XCTAssertFalse(code.contains(".disabled(viewModel.isPerformingAction)"),
                "\(url.lastPathComponent) must route in-flight enablement through policy.isEnabled, not a hand-rolled `.disabled(viewModel.isPerformingAction)`."
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
        try swiftFiles(under: "Soyeht")
    }

    /// macOS app sources. The Claw installability gate (theyos #88) must hold
    /// on the Mac surface too — `ClawDrawerViewController`, `MacClawCardView`,
    /// `MacClawDetailView` — not only the iPhone app.
    private func macSwiftFiles() throws -> [URL] {
        try swiftFiles(under: "SoyehtMac")
    }

    private func swiftFiles(under subdir: String) throws -> [URL] {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let root = terminalApp.appendingPathComponent(subdir)

        let enumerator = FileManager.default.enumerator(
            at: root,
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
