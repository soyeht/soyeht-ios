import XCTest

/// Source-guards (text-scan) for the race between the iPhone's radar and the
/// Mac's claim.
///
/// The mechanism, in English:
///
/// - The HMAC secret that puts a Mac on the phone's home (and lets it open a
///   pane) is minted only on the Mac and travels only inside the Mac's POST to
///   `/setup-invitation/claimed`. The radar path never carries one.
/// - So whichever of the two arrived first decided whether the person ended up
///   with a usable Mac. Measured on the Dev pair 2026-09-03: the Mac minted the
///   secret at 21:57:45Z, its claim landed at 21:57:50Z, and the phone's latch
///   dropped it.
///
/// `AwaitingMacView` and `SSHLoginView` are iPhone app code and
/// `SetupInvitationListener` is Mac app code; none of the three is in a target
/// the SwiftPM domain tests link, so — as in
/// `SetupInvitationListenerBootstrapErrorCodeGuardTests` and
/// `OnboardingRootsSourceGuardTests` — these guard the shape by reading the
/// source rather than calling the functions.
final class LateMacClaimSourceGuardTests: XCTestCase {

    // MARK: - The latch no longer drops a late claim

    func test_installProfileGuardRunsBeforeTheLatch_soALateClaimIsStillFiltered() throws {
        let handler = try claimHandler()

        let profileGuard = try XCTUnwrap(
            handler.range(of: "guard Self.engineURLMatchesCurrentInstallProfile(claim.macEngineURL) else {"),
            "the claim handler must still refuse a claim from another install profile"
        )
        let latch = try XCTUnwrap(
            handler.range(of: "if self.alreadyFound {"),
            "the claim handler must branch on alreadyFound instead of returning from it"
        )
        XCTAssertLessThan(
            profileGuard.lowerBound, latch.lowerBound,
            "the install-profile guard must run before the latch, so a late claim from the wrong build is dropped"
        )
        XCTAssertTrue(
            handler.contains("direct_claim_ignored_profile_mismatch"),
            "a claim from another install profile must still be logged as dropped"
        )
    }

    func test_theLatchHandsALateClaimToAcceptLateClaim_ratherThanDroppingIt() throws {
        let handler = try claimHandler()

        XCTAssertFalse(
            handler.contains("guard !self.alreadyFound else { return }"),
            "a Mac claim that arrives after the radar latched carries the only copy of the pairing secret — it must not be dropped"
        )
        XCTAssertTrue(
            handler.contains("self.acceptLateClaim(claim)"),
            "the alreadyFound branch must hand the claim to acceptLateClaim"
        )
    }

    func test_lateClaimWithoutASecret_isNothingToAccept() throws {
        let accept = try acceptLateClaimBody()
        XCTAssertTrue(
            accept.contains("guard let pairing = claim.macLocalPairing else {"),
            "acceptLateClaim exists for the secret; a claim without one has nothing to add"
        )
    }

    func test_lateClaimWithACandidatePending_rebuildsItCarryingTheSecret() throws {
        let accept = try acceptLateClaimBody()

        XCTAssertTrue(
            accept.contains("if let candidate = pendingExistingHouse {"),
            "with the 'is this your Mac?' card up, the secret must be deferred onto the candidate"
        )
        XCTAssertTrue(
            accept.contains("guard Self.claim(claim, matchesHouseholdOf: candidate) else {"),
            "a claim from another home must not slip its secret under the card on screen"
        )
        // Same rebuild `startOfferRefresh` does: the candidate is a value type,
        // so carrying the secret means replacing it field for field.
        for field in [
            "name: candidate.name",
            "hostLabel: candidate.hostLabel",
            "pairDeviceURI: candidate.pairDeviceURI",
            "engineURL: candidate.engineURL",
            "isDevicePairing: candidate.isDevicePairing",
            "deferredLocalPairing: pairing",
        ] {
            XCTAssertTrue(
                accept.contains(field),
                "the rebuilt candidate must carry \(field)"
            )
        }
    }

    func test_lateClaimAfterThePairingFinished_installsTheSecretItself() throws {
        let accept = try acceptLateClaimBody()

        XCTAssertTrue(
            accept.contains("guard !installedLocalPairingForDiscovery else {"),
            "a secret already installed must not be installed twice"
        )
        XCTAssertTrue(
            accept.contains("installMacLocalPairing(pairing)"),
            "with no card on screen the engine pairing is done and the secret is the only thing missing"
        )
        XCTAssertTrue(
            accept.contains("installedLocalPairingForDiscovery = true"),
            "installing the secret must record that this discovery can now open the Mac"
        )
    }

    func test_householdMatchReadsHhPub_andFallsBackToTheEngineHost() throws {
        let match = try slice(
            try codeOnly(awaitingMacSource()),
            from: "private static func claim(",
            to: "    func stop() {"
        )
        XCTAssertTrue(
            match.contains("householdKey(of: claimedURL)") && match.contains("householdKey(of: candidate.pairDeviceURI)"),
            "the household match must compare hh_pub — the only part of the link that holds still while the nonce rotates"
        )
        XCTAssertTrue(
            match.contains("claim.macEngineURL.host == candidate.engineURL.host"),
            "a claim carrying no household must fall back to the engine host"
        )
    }

    func test_connectReadsTheCandidateRebuiltWhileItWasInFlight() throws {
        let connect = try slice(
            try codeOnly(awaitingMacSource()),
            from: "func connectToExistingHouse() {",
            to: "enum ConnectFailureReason"
        )
        XCTAssertTrue(
            connect.contains("self.pendingExistingHouse?.deferredLocalPairing")
                && connect.contains("?? house.deferredLocalPairing"),
            "`house` is the copy taken at tap time; a claim that landed mid-Connect rebuilt the candidate and that copy carries the secret"
        )
    }

    // MARK: - "Tailscale is off on this iPhone" instead of the catch-all

    func test_connectFailureNamesTailscaleOff_whenTheLinkIsTailnetAndThePhoneIsNot() throws {
        let source = try codeOnly(awaitingMacSource())

        XCTAssertTrue(
            source.contains("case tailscaleOffOnThisIPhone"),
            "the phone can distinguish this one cause; it must have a case of its own"
        )
        let reason = try slice(
            source,
            from: "static func connectFailureReason(",
            to: "static func pairingLinkHost("
        )
        XCTAssertTrue(
            reason.contains("guard tailnetIPv4 == nil else { return .unknown }"),
            "with a tailnet address on this iPhone, Tailscale is not the explanation"
        )
        XCTAssertTrue(
            reason.contains("HostClassifier.isTailnetIPv4(host)"),
            "the 100.64/10 test must come from HostClassifier, not a hand-rolled prefix check"
        )

        // From the end of the approval-timed-out catch to the reason type:
        // exactly the generic catch that used to answer every failure.
        let catchBlock = try slice(
            source,
            from: "\"awaitingMac.existingHouse.connect.approvalTimedOut\",",
            to: "enum ConnectFailureReason"
        )
        XCTAssertTrue(
            catchBlock.contains("TailnetAddressResolver.currentTailnetIPv4()"),
            "the failure message must be chosen against this iPhone's live tailnet address"
        )
        XCTAssertTrue(
            catchBlock.contains("Self.connectFailureMessage(reason)"),
            "the catch must ask for the message that matches the reason, not hardcode one"
        )
    }

    func test_pairingLinkHostPrefersTheLinksOwnEndpoint_thenItsHostFallback() throws {
        let host = try slice(
            try codeOnly(awaitingMacSource()),
            from: "static func pairingLinkHost(",
            to: "private static func connectFailureMessage("
        )
        let endpoint = try XCTUnwrap(host.range(of: "$0.name == \"endpoint\""))
        let fallback = try XCTUnwrap(host.range(of: "$0.name == \"host\""))
        XCTAssertLessThan(
            endpoint.lowerBound, fallback.lowerBound,
            "a Mac-minted device-pairing link carries `endpoint`; the engine-minted `host` fallback is the second answer"
        )
        XCTAssertTrue(
            host.contains("return engineURL.host"),
            "a link carrying neither must fall back to the engine URL the Mac was found on"
        )
    }

    func test_theTailscaleOffMessageIsInTheCatalogInEveryLocale() throws {
        let catalog = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: repoURL("TerminalApp/Soyeht/Localizable.xcstrings"))
        )
        let strings = try XCTUnwrap((catalog as? [String: Any])?["strings"] as? [String: Any])
        let entry = try XCTUnwrap(
            strings["awaitingMac.existingHouse.connect.tailscaleOff"] as? [String: Any],
            "the new reason needs a catalog entry beside awaitingMac.existingHouse.connect.failed"
        )
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let neighbour = try XCTUnwrap(
            (strings["awaitingMac.existingHouse.connect.failed"] as? [String: Any])?["localizations"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(localizations.keys), Set(neighbour.keys),
            "the new string must ship in exactly the locales its neighbour ships in"
        )
    }

    // MARK: - The recovery window is bounded by the person, not by a stopwatch

    func test_recoveryWindowHasNoDeadline_andReArmsBeforeTheInvitationLapses() throws {
        let source = try codeOnly(sshLoginSource())

        XCTAssertTrue(
            source.contains("startMacLocalPairingPublisher(lifetime: .whileActiveAndMacless)"),
            "the household recovery invitation is the window that must outlive a 45 s timer"
        )
        let whileActive = try slice(
            source,
            from: "case .whileActiveAndMacless:",
            to: "    @MainActor\n    private func stopMacLocalPairingPublisher()"
        )
        XCTAssertFalse(
            whileActive.contains("45_000_000_000"),
            "the recovery window must not carry the old 45 s deadline"
        )
        XCTAssertTrue(
            whileActive.contains("startMacLocalPairingPublisher(")
                && whileActive.contains("macLocalPairingInvitationRenewal"),
            "the invitation's own expiry is finite, so the window must re-mint rather than lapse"
        )
        XCTAssertTrue(
            whileActive.contains("ServerRegistry.shared.operationalMacs.isEmpty"),
            "a home that gained a Mac has nothing left to recover"
        )
    }

    func test_theDevicePairingHandshakeKeepsItsOwnDeadline() throws {
        let source = try codeOnly(sshLoginSource())
        let devicePairing = try slice(
            source,
            from: "private func startDevicePairingSetupInvitation(",
            to: "private func startHouseholdMacRecoveryInvitation("
        )
        XCTAssertTrue(
            devicePairing.contains("lifetime: .bounded(seconds: 45)"),
            "the pair-device handshake has a definite end and nothing else stops its publisher"
        )
    }

    func test_theWindowClosesOnResign_reopensOnActive_andEndsWhenAMacLands() throws {
        let source = try codeOnly(sshLoginSource())

        let resign = try slice(
            source,
            from: "UIApplication.willResignActiveNotification",
            to: "UIApplication.protectedDataDidBecomeAvailableNotification"
        )
        XCTAssertTrue(
            resign.contains("stopHouseholdMacRecoveryInvitation()"),
            "a Bonjour publisher the person cannot see must come down with the app"
        )

        let becomeActive = try slice(
            source,
            from: "UIApplication.didBecomeActiveNotification",
            to: "UIApplication.willResignActiveNotification"
        )
        XCTAssertTrue(
            becomeActive.contains("startHouseholdMacRecoveryInvitation(for: identity)"),
            "coming back to the app must reopen the window"
        )
        XCTAssertTrue(
            becomeActive.contains("case .instanceList, .householdHome:"),
            "both screens that arm the window must re-arm it, or backgrounding on one of them silences the phone for good"
        )

        let macsLanded = try slice(
            source,
            from: ".onReceive(macsStoreBox.$macs)",
            to: "soyehtColorThemeChanged"
        )
        XCTAssertTrue(
            macsLanded.contains("stopHouseholdMacRecoveryInvitation()"),
            "the home has its Mac — that is the window's other end"
        )
    }

    func test_onlyTheRecoveryWindowClosesOnResign() throws {
        let source = try codeOnly(sshLoginSource())
        let stop = try slice(
            source,
            from: "private func stopHouseholdMacRecoveryInvitation() {",
            to: "nonisolated private static func devicePairingClaim("
        )
        XCTAssertTrue(
            stop.contains("guard macLocalPairingPublisherIsRecoveryWindow else { return }"),
            "a pair-device approval the person is in the middle of must survive a banner pulling the app out of active"
        )
    }

    // MARK: - Mac side

    func test_anEngineMintedOfferIsRefreshedOnceTheEngineReadsReady() throws {
        let payload = try slice(
            try codeOnly(listenerSource()),
            from: "private func makeExistingHousePayload()",
            to: "private static func engineIsReady()"
        )
        XCTAssertTrue(
            payload.contains("offer.isEngineMinted") && payload.contains("Self.engineIsReady()"),
            "the engine's link stops being accepted the moment the engine leaves named_awaiting_pair; the check must be conditioned on both"
        )
        XCTAssertTrue(
            payload.contains("MacPairingAdvertisement.shared.invalidate()"),
            "a closed engine link must be dropped so the next read mints the Mac's own"
        )
    }

    func test_theEngineSayingAlreadyInitializedIsLogged() throws {
        let source = try codeOnly(listenerSource())
        XCTAssertTrue(
            source.contains("BootstrapErrorCode(wire: code) == .alreadyInitialized"),
            "the already-initialized answer must be recognised through the typed code"
        )
        XCTAssertTrue(
            source.contains("direct_probe.claim_already_initialized"),
            "the claim loop is otherwise invisible on the Mac"
        )
    }

    func test_aDeviceClaimedSecondsAgoIsNotClaimedAgain() throws {
        let source = try codeOnly(listenerSource())

        let probe = try slice(
            source,
            from: "private func listenViaTailscalePeerProbe()",
            to: "private func claimWithRetry("
        )
        let suppress = try XCTUnwrap(
            probe.range(of: "RecentSetupInvitationClaims.shared.isRecent(deviceID)"),
            "the loop comes round every few seconds and two Mac profiles chase the same phone"
        )
        let record = try XCTUnwrap(
            probe.range(of: "RecentSetupInvitationClaims.shared.record(deviceID)"),
            "only a ceremony that actually reached the phone should suppress the next one"
        )
        XCTAssertLessThan(
            suppress.lowerBound, record.lowerBound,
            "the suppression check belongs before the claim; the record belongs after the notify succeeded"
        )
        XCTAssertTrue(
            source.contains("static let window: TimeInterval = 5"),
            "the window must be a named constant, in seconds"
        )
    }

    // MARK: - Sources

    private func awaitingMacSource() throws -> String {
        try repoSource("TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift")
    }

    private func sshLoginSource() throws -> String {
        try repoSource("TerminalApp/Soyeht/SSHLoginView.swift")
    }

    private func listenerSource() throws -> String {
        try repoSource("TerminalApp/SoyehtMac/Welcome/SetupInvitationListener/SetupInvitationListener.swift")
    }

    /// The body of `publisher.onMacClaimed`, which is where the race is decided.
    private func claimHandler() throws -> String {
        try slice(
            try codeOnly(awaitingMacSource()),
            from: "publisher.onMacClaimed = { [weak self] claim in",
            to: "publisher.start()"
        )
    }

    private func acceptLateClaimBody() throws -> String {
        try slice(
            try codeOnly(awaitingMacSource()),
            from: "private func acceptLateClaim(",
            to: "private static func claim("
        )
    }

    // MARK: - Text helpers (same shape as OnboardingRootsSourceGuardTests)

    private func repoURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
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
        let start = try XCTUnwrap(
            source.range(of: startMarker),
            "start marker not found: \(startMarker)"
        )
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(
            tail.range(of: endMarker),
            "end marker not found after \(startMarker): \(endMarker)"
        )
        return String(tail[..<end.lowerBound])
    }
}
