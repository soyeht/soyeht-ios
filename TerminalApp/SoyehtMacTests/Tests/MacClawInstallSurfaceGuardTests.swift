import XCTest

/// E2b: Mac-tree SOURCE GUARD for the Claw Store install surfaces.
///
/// E1/E2a converged the macOS install affordances onto a shared, readiness-aware
/// install decision so the guest-image gate can't be bypassed. This guard locks
/// that in: every macOS install BUTTON must consult a readiness-aware decision
/// unit, and no NEW install surface can quietly re-derive the rule inline — that
/// is the bug #1 class (the drawer once installed without the guest-image gate
/// while the Store enforced it).
///
/// It deliberately scans the real `SoyehtMac/ClawStore` app tree from disk (via
/// `#filePath`) rather than the symlinked domain sources, mirroring the iOS
/// `ClawRouteUsageTests` approach — the SwiftUI/AppKit view layer is not
/// otherwise reachable from this domain test package. (This is the macOS
/// counterpart the iOS-only `ClawRouteUsageTests`/`LegacyBoundaryUsageTests`
/// never had.)
final class MacClawInstallSurfaceGuardTests: XCTestCase {

    /// The install-button label keys every install affordance renders
    /// (`claw.card.button.install`, `claw.detail.button.install`,
    /// `drawer.button.install`) all contain this substring.
    private let installButtonMarker = "button.install"

    /// The readiness-aware decision units an install surface may consult. BOTH
    /// fold the guest-image readiness gate in:
    ///   - `MacClawInstallDecision` — the list/grid surfaces (card, drawer row),
    ///   - `ClawDetailActionAvailability` — the detail surface.
    private let readinessAwareGates = ["MacClawInstallDecision", "ClawDetailActionAvailability"]

    /// The install surfaces that exist today. A NEW file that renders an install
    /// button trips `test_noUnaccountedInstallSurface`, forcing whoever adds it
    /// to wire a readiness-aware gate and register it here on purpose.
    private let knownInstallSurfaces: Set<String> = [
        "ClawDrawerViewController.swift",
        "MacClawCardView.swift",
        "MacClawDetailView.swift",
    ]

    func test_everyInstallButtonSurfaceConsultsAReadinessAwareGate() throws {
        let surfaces = try installButtonSurfaces()
        XCTAssertFalse(surfaces.isEmpty, "Expected to find at least one macOS install-button surface")
        for url in surfaces {
            let code = try codeOnly(at: url)
            let consultsGate = readinessAwareGates.contains { code.contains($0) }
            XCTAssertTrue(consultsGate,
                "\(url.lastPathComponent) renders an install button but does not consult a readiness-aware install gate (\(readinessAwareGates.joined(separator: " or "))). Install affordances must NOT re-derive the install rule inline — route them through the shared decision so the guest-image readiness gate can't be bypassed (bug #1 class)."
            )
        }
    }

    func test_noUnaccountedInstallSurface() throws {
        let found = Set(try installButtonSurfaces().map(\.lastPathComponent))
        XCTAssertEqual(found, knownInstallSurfaces,
            "The set of macOS Claw Store install-button surfaces changed. A new surface must consult a readiness-aware gate (MacClawInstallDecision or ClawDetailActionAvailability) and be registered in `knownInstallSurfaces`. Found: \(found.sorted()); expected: \(knownInstallSurfaces.sorted())."
        )
    }

    /// PR-2: the grid action site (`MacClawStoreRootView.onInstall`) must re-check
    /// the readiness-aware install gate live at tap time, not rely only on the
    /// card's last-rendered visibility. Otherwise a readiness change between render
    /// and tap lets a stale tap POST an install the guest-image gate would block.
    /// (The detail surface gates by visibility via `ClawDetailActionAvailability`;
    /// the drawer already guards its action site with `shouldIssueInstall`.)
    func test_gridInstallActionSiteConsultsReadinessAwareGate() throws {
        let root = try clawStoreSwiftFiles().first { $0.lastPathComponent == "MacClawStoreRootView.swift" }
        let url = try XCTUnwrap(root, "Expected MacClawStoreRootView.swift in SoyehtMac/ClawStore")
        let code = try codeOnly(at: url)

        let callRange = try XCTUnwrap(code.range(of: "viewModel.installClaw("),
            "Expected MacClawStoreRootView to host the grid install action (onInstall -> viewModel.installClaw).")

        // The gate must appear in the LOCAL block immediately preceding the install
        // call (the onInstall closure body), not merely somewhere else in the file -
        // otherwise moving the guard elsewhere would leave the call ungated while the
        // test stayed vacuously green. We check a small fixed window before the call.
        let windowSize = 400
        let windowStart = code.index(callRange.lowerBound, offsetBy: -windowSize, limitedBy: code.startIndex) ?? code.startIndex
        let precedingWindow = String(code[windowStart..<callRange.lowerBound])
        let gatedRightBeforeCall = precedingWindow.contains("shouldIssueInstall") || precedingWindow.contains("mayIssueInstall")
        XCTAssertTrue(gatedRightBeforeCall,
            "MacClawStoreRootView's grid onInstall must guard on a readiness-aware action gate (MacClawInstallDecision.shouldIssueInstall / ClawActionPolicy.mayIssueInstall) IMMEDIATELY BEFORE calling viewModel.installClaw, so a stale tap cannot bypass the guest-image readiness gate and the gate cannot drift away from the call site."
        )
    }

    /// E3 (mini): the macOS Claw Store path resolves its active target through
    /// `MacActiveServerContextResolver` (canonical inventory metadata + credential),
    /// NEVER `SessionStore.currentContext()` — which sources metadata from the
    /// legacy `pairedServers` view and can drift from the canonical row after the
    /// ServerStore migration.
    func test_clawStorePathResolvesActiveTargetThroughResolverNotCurrentContext() throws {
        let offenders = try clawStoreSwiftFiles().filter { url in
            ((try? codeOnly(at: url)) ?? "").contains("currentContext()")
        }
        XCTAssertTrue(offenders.isEmpty,
            "macOS Claw Store files must resolve the active target via MacActiveServerContextResolver, not SessionStore.currentContext() (legacy metadata that can drift from the canonical row). Offending: \(offenders.map(\.lastPathComponent))"
        )

        let usesResolver = try clawStoreSwiftFiles().contains { url in
            ((try? codeOnly(at: url)) ?? "").contains("MacActiveServerContextResolver")
        }
        XCTAssertTrue(usesResolver,
            "Expected the macOS Claw Store path to resolve its active target through MacActiveServerContextResolver."
        )
    }

    // MARK: - Helpers

    private func installButtonSurfaces() throws -> [URL] {
        try clawStoreSwiftFiles().filter { url in
            let code = (try? codeOnly(at: url)) ?? ""
            return code.contains(installButtonMarker)
        }
    }

    private func clawStoreSwiftFiles() throws -> [URL] {
        let clawStore = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent("ClawStore")

        let enumerator = FileManager.default.enumerator(
            at: clawStore,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty, "Expected SoyehtMac/ClawStore swift files at \(clawStore.path)")
        return files
    }

    /// Returns the file with comment-only lines stripped, so a doc-comment that
    /// mentions a marker or gate name can't satisfy (or trip) the invariants.
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
}
