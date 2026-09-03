import XCTest

/// Source guards for the neo home (S8) and for the `open_pane` round trip it
/// rides on. Both apps are involved, so the guards live in the SwiftPM suite:
/// it reads the repository from disk and links neither AppKit nor UIKit.
///
/// The contracts, in English:
///
/// 1. The home renders the canonical `displayName`, never a raw identifier,
///    and never reaches into `PairedMacsStore.shared.macs` — the legacy
///    boundary `LegacyBoundaryUsageTests` polices for every other iOS screen.
/// 2. Leaving a household is a Settings decision. The `person.2` icon that
///    used to sit in the home's toolbar is gone, and `onLogout` is optional
///    so no call site is forced to invent one.
/// 3. "New session" goes through `open_pane` — the phone asks, the Mac
///    creates. The phone never invents a pane id of its own to attach to.
/// 4. Every Mac a pairing path writes gets a default alias in the same turn,
///    at all three funnel sites, so the home never has a nameless row.
final class HomeNeoSourceGuardTests: XCTestCase {

    // MARK: - The home

    func test_theHomeReadsTheCanonicalDisplayNameAndNotTheLegacyStore() throws {
        let model = try codeOnly(repoSource("TerminalApp/Soyeht/Home/Neo/HomeViewModel.swift"))

        XCTAssertTrue(model.contains("primary.displayName"))
        XCTAssertTrue(model.contains("servers.operationalMacs"))
        XCTAssertTrue(model.contains("macs.client(for: macID)"))

        // The two legacy collections the facades exist to hide.
        XCTAssertFalse(model.contains("PairedMacsStore.shared.macs"))
        XCTAssertFalse(model.contains("SessionStore.shared.pairedServers"))
    }

    func test_theHomeDoesNotOfferLogoutAndTheInstanceListNoLongerRequiresIt() throws {
        let home = try codeOnly(repoSource("TerminalApp/Soyeht/Home/Neo/HomeView.swift"))
        XCTAssertFalse(home.contains("person.2"))
        XCTAssertFalse(home.contains("onLogout"))

        let list = try codeOnly(repoSource("TerminalApp/Soyeht/InstanceListView.swift"))
        XCTAssertTrue(list.contains("var onLogout: (() -> Void)? = nil"))
        XCTAssertTrue(list.contains("if let onLogout {"))
    }

    func test_theInstanceListIsReachableOnlyBehindOtherMachines() throws {
        let login = try codeOnly(repoSource("TerminalApp/Soyeht/SSHLoginView.swift"))

        // The home owns the `.instanceList` route now; the old list is one
        // level down, behind its own cover.
        XCTAssertTrue(login.contains("HomeView("))
        XCTAssertTrue(login.contains("onOtherMachines: { showOtherMachines = true }"))
        XCTAssertTrue(login.contains(".fullScreenCover(isPresented: $showOtherMachines)"))

        // The banner and the pair-request overlay keep their place above the
        // home — the shape `DevicePairApprovalPresentationTests` pins.
        XCTAssertTrue(login.contains("RosterAlertBanner("))
        XCTAssertTrue(login.contains("HouseholdDevicePairRequestOverlay("))
    }

    // MARK: - open_pane

    func test_openPaneIsOneFrameInEachDirection() throws {
        let wire = try codeOnly(repoSource("Packages/SoyehtCore/Sources/SoyehtCore/Pairing/PresenceProtocol.swift"))
        XCTAssertTrue(wire.contains("let openPane"))
        XCTAssertTrue(wire.contains("= \"open_pane\""))
        XCTAssertTrue(wire.contains("let openPaneResult"))
        XCTAssertTrue(wire.contains("= \"open_pane_result\""))
    }

    func test_theMacCreatesThePaneAndAnswersWithItsID() throws {
        let session = try codeOnly(repoSource("TerminalApp/SoyehtMac/Pairing/PresenceSession.swift"))
        XCTAssertTrue(session.contains("case PresenceMessage.openPane:"))
        XCTAssertTrue(session.contains("handleOpenPane()"))
        XCTAssertTrue(session.contains("PresenceMessage.openPaneResult"))
        XCTAssertTrue(session.contains(PresenceOpenPaneWire.paneID))

        let delegate = try codeOnly(repoSource("TerminalApp/SoyehtMac/AppDelegate.swift"))
        XCTAssertTrue(delegate.contains("func openLocalShellPaneForPresence()"))
        XCTAssertTrue(delegate.contains("agentName: \"shell\""))
    }

    func test_thePhoneAsksTheMacInsteadOfInventingAPaneID() throws {
        let client = try codeOnly(repoSource("TerminalApp/Soyeht/Pairing/MacPresenceClient.swift"))
        XCTAssertTrue(client.contains("func requestOpenPane("))
        XCTAssertTrue(client.contains("pendingOpenPane"))
        XCTAssertTrue(client.contains("handleOpenPaneResult"))

        let model = try codeOnly(repoSource("TerminalApp/Soyeht/Home/Neo/HomeViewModel.swift"))
        XCTAssertTrue(model.contains("try await client.requestOpenPane()"))
        // The id the phone attaches to is the Mac's answer, never a local UUID.
        XCTAssertFalse(model.contains("UUID().uuidString"))
    }

    func test_openPaneFailuresSpeakInTheProductsVoice() throws {
        let client = try codeOnly(repoSource("TerminalApp/Soyeht/Pairing/MacPresenceClient.swift"))
        for key in [
            "presence.error.openPaneBusy",
            "presence.error.openPaneUnsupported",
            "presence.error.openPaneDisconnected",
            "presence.error.openPaneRefused"
        ] {
            XCTAssertTrue(client.contains(key), "missing localized message \(key)")
        }
    }

    // MARK: - The alias funnel

    func test_everyPairingPathNamesTheMacItWrites() throws {
        let sites = [
            "TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift",
            "TerminalApp/Soyeht/SSHLoginView.swift",
            "TerminalApp/Soyeht/Pairing/PairingCoordinator.swift"
        ]
        for path in sites {
            let source = try codeOnly(repoSource(path))
            XCTAssertTrue(
                source.contains("setDefaultMacAliasIfNeeded("),
                "\(path) writes a Mac pairing without giving the row a name"
            )
        }
    }

    // MARK: - Helpers

    /// Wire literals the guard asserts on, kept out of the assertions above so
    /// a reader sees the contract and not the quoting.
    private enum PresenceOpenPaneWire {
        static let paneID = "pane_id"
    }

    private func repoSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
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
}
