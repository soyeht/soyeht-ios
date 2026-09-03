import XCTest

/// Source guards for the iPhone's Layer-A onboarding roots (S6).
///
/// The contracts, in English:
///
/// 1. Every root the `SceneDelegate` installs is hosted by
///    `OnboardingHostingController`. The window is dark and the onboarding is
///    drawn on a light canvas, so a root hosted by a bare `UIHostingController`
///    shows a black seam and a white-on-white status bar.
/// 2. Nothing under `Onboarding/Neo/` reaches for the old palettes. The neo
///    screens read `NeoPalette`; `BrandColors` and `SoyehtTheme` follow the
///    user's terminal theme, which is not what these screens are wearing.
/// 3. The screens the new path no longer reaches are gone from the tree, not
///    merely unreferenced — including the feature flag that could only ever be
///    false.
final class OnboardingRootsSourceGuardTests: XCTestCase {

    private static let layerARoots = [
        "WelcomeView(",
        "MacPresenceQuestionView(",
        "AwaitingMacView("
    ]

    func test_everyLayerARootIsHostedByTheOnboardingController() throws {
        let delegate = try codeOnly(repoSource("TerminalApp/Soyeht/AppDelegate.swift"))

        for root in Self.layerARoots {
            let presenter = try XCTUnwrap(
                presenterHosting(root, in: delegate),
                "\(root) is not presented as a window root in AppDelegate"
            )
            XCTAssertEqual(
                presenter, "OnboardingHostingController",
                "\(root) must be hosted by OnboardingHostingController, not \(presenter)"
            )
        }
    }

    func test_theNeoOnboardingScreensReadTheNeoPaletteOnly() throws {
        for url in try neoOnboardingFiles() {
            let source = try codeOnly(String(contentsOf: url, encoding: .utf8))
            let name = url.lastPathComponent
            // RestoredFromBackupView still wears the old palette; it is
            // restyled in the retirement slice, not this one.
            guard name != "RestoredFromBackupView.swift" else { continue }
            XCTAssertFalse(source.contains("BrandColors."), "\(name) reads BrandColors")
            XCTAssertFalse(source.contains("SoyehtTheme."), "\(name) reads SoyehtTheme")
        }
    }

    func test_theRetiredOnboardingScreensAreGoneFromTheTree() throws {
        let retired = [
            "TerminalApp/Soyeht/Onboarding/Carousel",
            "TerminalApp/Soyeht/Onboarding/ParkingLot",
            "TerminalApp/Soyeht/Onboarding/Proximity/ProximityQuestionView.swift",
            "TerminalApp/Soyeht/Onboarding/Proximity/QRFallbackView.swift",
            "TerminalApp/Soyeht/Onboarding/Proximity/AirDropPresenter.swift",
            "TerminalApp/Soyeht/Onboarding/Proximity/CellularConfirmationSheet.swift",
            "TerminalApp/Soyeht/Onboarding/Proximity/NetworkDownloadGuard.swift",
            "TerminalApp/Soyeht/Onboarding/InstallPicker/ResidentExplainerView.swift",
            "TerminalApp/Soyeht/Settings/ReshowTourView.swift"
        ]
        for path in retired {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoURL(path).path),
                "\(path) should have been retired with the carousel path"
            )
        }

        let picker = try codeOnly(repoSource("TerminalApp/Soyeht/Onboarding/InstallPicker/InstallPickerView.swift"))
        XCTAssertFalse(picker.contains("struct InstallPickerView"))
        XCTAssertTrue(picker.contains("struct LinuxPairingGuideView"), "the Linux guide still has a home here")
        XCTAssertTrue(picker.contains("enum OnboardingLaunchIntent"))
    }

    func test_theOnlyQuestionBeforeTheRadarIsWhetherTheMacHasSoyeht() throws {
        let question = try codeOnly(repoSource("TerminalApp/Soyeht/Onboarding/Neo/MacPresenceQuestionView.swift"))

        // Both answers end on the radar — the phone looks either way. Only the
        // Linux answer leaves the Mac path.
        XCTAssertTrue(question.contains("let onAlreadyInstalled: () -> Void"))
        XCTAssertTrue(question.contains("let onNeedsInstall: () -> Void"))
        XCTAssertTrue(question.contains("let onLinux: () -> Void"))
        XCTAssertTrue(question.contains("MacDownloadLink.latestDMG"))

        let delegate = try codeOnly(repoSource("TerminalApp/Soyeht/AppDelegate.swift"))
        let routing = try slice(delegate, from: "MacPresenceQuestionView(", to: "private func showLinuxPairingGuide")
        XCTAssertEqual(
            routing.components(separatedBy: "beginMacNearbyFlow(in: window)").count - 1, 2,
            "both non-Linux answers must start the search"
        )
    }

    func test_aMacThatAlreadyHasAHomeIsNotCalledUnreachable() throws {
        let radar = try codeOnly(repoSource("TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift"))

        // `.ready` with no local pairing used to fall into `retryLater`, which
        // prints "Mac unreachable @ host:port" under a spinning radar — about
        // a Mac that is answering every probe.
        XCTAssertTrue(radar.contains("case macAlreadyHasHome"))
        XCTAssertTrue(radar.contains("canOpenExistingMac ? .connectedToExistingMac : .macAlreadyHasHome"))
        XCTAssertTrue(radar.contains(".stalled(.macUnreachable(.alreadyHasHome))"))
        XCTAssertTrue(radar.contains("onboarding.notFound.cause.alreadyHasHome.title"))
        XCTAssertTrue(radar.contains("onboarding.looking.status.alreadyHasHome"))

        let phases = try codeOnly(repoSource("Packages/SoyehtCore/Sources/SoyehtCore/Onboarding/MacDiscoveryPhase.swift"))
        XCTAssertTrue(phases.contains("case alreadyHasHome"))
    }

    // MARK: - Helpers

    /// The identifier of the hosting controller that presents `root` — read by
    /// walking back from the root's construction to the nearest
    /// `…HostingController(rootView:` that opens it.
    private func presenterHosting(_ root: String, in source: String) -> String? {
        guard let hit = source.range(of: root) else { return nil }
        let head = source[..<hit.lowerBound]
        guard let open = head.range(of: "HostingController(rootView:", options: .backwards) else { return nil }
        let prefix = head[..<open.lowerBound]
        let name = prefix.reversed().prefix { $0.isLetter }.reversed()
        return String(name) + "HostingController"
    }

    private func neoOnboardingFiles() throws -> [URL] {
        let root = repoURL("TerminalApp/Soyeht/Onboarding/Neo")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return names.filter { $0.hasSuffix(".swift") }.map { root.appendingPathComponent($0) }
    }

    private func repoURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func repoSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoURL(relativePath), encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
