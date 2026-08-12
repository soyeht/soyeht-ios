import CryptoKit
import XCTest
import SoyehtCore
@testable import Soyeht

final class QRScannerViewMachineDispatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPairMachineRoutesToJoinRequestEnvelope() throws {
        let url = try makePairMachineURL(transport: .tailscale)

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: "hh_test", now: now)
            .get()

        guard case .householdPairMachine(let envelope) = result else {
            XCTFail("Expected pair-machine to route to JoinRequestEnvelope")
            return
        }
        XCTAssertEqual(envelope.householdId, "hh_test")
        XCTAssertEqual(envelope.rawHostname, "mac-alpha.local")
        XCTAssertEqual(envelope.rawPlatform, "macos")
        XCTAssertEqual(envelope.candidateAddress, "100.64.0.10:8443")
        XCTAssertEqual(envelope.transportOrigin, .qrTailscale)
        XCTAssertEqual(envelope.ttlUnix, UInt64(now.timeIntervalSince1970) + 240)
        XCTAssertEqual(envelope.receivedAt, now)
    }

    func testPairDeviceRoutesToPhase2PairingWhenNoActiveHousehold() throws {
        // The founding-owner ceremony only makes sense from a clean
        // device. With no `activeHouseholdId`, the dispatcher must
        // accept the QR and forward it to the Phase 2 pair flow.
        let url = try makePairDeviceURL()

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .householdPairDevice(let routedURL) = result else {
            XCTFail("Expected pair-device to keep Phase 2 route")
            return
        }
        XCTAssertEqual(routedURL, url)
    }

    func testPairDeviceRefusedWhenSessionAlreadyActive() throws {
        // Threat model: any installed app (or the iOS Camera-app QR
        // banner) can deliver a `soyeht://household/pair-device` URL
        // unprompted. Accepting it on a device that is already a
        // household member would silently overwrite the owner cert,
        // drop APNS registration tied to the previous `personId`, and
        // break gossip continuity. Refuse with the dedicated error so
        // the caller can surface an "already paired" message instead
        // of pairing into oblivion. Closes the deep-link hijack vector
        // raised in the PR #60 review.
        let url = try makePairDeviceURL()

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: "hh_existing",
            now: now
        )

        switch result {
        case .success:
            XCTFail("pair-device must be refused when a session is already active")
        case .failure(let error):
            XCTAssertEqual(error, .householdPairDeviceSessionAlreadyActive)
        }
    }

    func testPairMachineRequiresActiveHouseholdBeforeEnvelopeEmission() throws {
        let url = try makePairMachineURL(transport: .lan)

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: nil,
            now: now
        )

        guard case .failure(.machineJoin(.hhMismatch)) = result else {
            XCTFail("Expected pair-machine without an active household to fail as household mismatch")
            return
        }
    }

    func testLegacyTheyOSConnectStillRoutesThroughLegacyResult() throws {
        let url = try XCTUnwrap(URL(string: "theyos://connect?token=abc&host=mac.local"))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: "hh_test", now: now)
            .get()

        guard case .connect(let token, let host) = result else {
            XCTFail("Expected legacy connect result")
            return
        }
        XCTAssertEqual(token, "abc")
        XCTAssertEqual(host, "mac.local")
    }

    func testLegacyTheyOSPairRoutesFromLinuxOnboarding() throws {
        let url = try XCTUnwrap(URL(string: "theyos://pair?token=pair-abc&host=linux.local"))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .pair(let token, let host) = result else {
            XCTFail("Expected Linux pairing link to route through legacy pair result")
            return
        }
        XCTAssertEqual(token, "pair-abc")
        XCTAssertEqual(host, "linux.local")
    }

    /// Subject: WHICH parser owns this URL. It used to also assert that the
    /// onboarding router ignores invites — true when this test was written
    /// (2026-06-24, `8777b4bd`), because invites then arrived only by scanner
    /// or paste and the deep-link path did not exist yet. The matcher and
    /// handler were added later; the routing half was not, which is what left
    /// an invited guest staring at the install picker.
    ///
    /// Routing now has its own home in
    /// `testClawShareInviteOpensMainStoryboardSoAGuestWithNoHouseholdCanSeeIt`,
    /// so the stale assertion is not flipped here — it is moved, one property
    /// per test.
    func testClawShareInviteRoutesOnlyThroughScannerDispatcher() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertNil(QRScanResult.from(url: url))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .clawShareInvite(let routedInvite) = result else {
            XCTFail("Expected scanner dispatcher to route claw-share invite")
            return
        }
        XCTAssertEqual(routedInvite, invite)
    }

    /// The deep-link path must recognise a claw-share invite *before* it
    /// reaches the `QRScanResult.from(url:)` fallback, because that fallback
    /// returns nil for these — asserted directly in
    /// `testClawShareInviteRoutesOnlyThroughScannerDispatcher` above. Until
    /// this matcher existed, a tapped invite link launched the app (Info.plist
    /// claims the `soyeht` scheme), matched no branch, hit that nil, and the
    /// handler returned silently: the guest saw the app open and do nothing.
    func testClawShareInviteURLIsClaimedByTheDeepLinkMatcher() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertTrue(PendingClawShareInvite.matches(url))
        // The property that makes the matcher necessary rather than merely
        // tidy: nothing else on the deep-link path claims this URL.
        XCTAssertNil(QRScanResult.from(url: url))
    }

    /// The matcher must not poach URLs that already have a home, or it would
    /// divert pairing into the invite sheet.
    func testDeepLinkMatcherIgnoresEveryOtherRoutedURLShape() throws {
        let others = [
            "theyos://instance/inst-123",
            "theyos://connect?local_handoff=mac_local",
            "theyos://pair?token=pair-abc&host=linux.local",
            "soyeht://household/pair-device?v=1&nonce=abc",
            "soyeht://household/pair-machine?v=1&nonce=abc",
            "soyeht://debug/reset-local-state"
        ]
        for raw in others {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(
                PendingClawShareInvite.matches(url),
                "\(raw) must keep its own branch"
            )
        }
    }

    /// A URL carrying the invite prefix but an undecodable payload must be
    /// claimed by the matcher and then *refused* by the dispatcher — never
    /// waved on to another branch that would misread it.
    func testMalformedClawShareURLIsClaimedThenRefused() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        XCTAssertTrue(PendingClawShareInvite.matches(url))
        switch QRScannerDispatcher.result(for: url, activeHouseholdId: nil, now: now) {
        case .success(let result):
            XCTFail("malformed invite must not classify as \(result)")
        case .failure:
            break
        }
    }

    func testClawShareInviteInvalidReturnsTypedScanError() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: nil,
            now: now
        )

        guard case .failure(.clawShareInviteInvalid) = result else {
            XCTFail("Expected invalid claw-share invite to return typed scan error")
            return
        }
    }

    func testServerPairingDeepLinksOpenMainStoryboardDuringOnboarding() throws {
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://pair?token=pair-abc&host=linux.local"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://connect?token=abc&host=mac.local"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://invite?token=abc&host=mac.local"))
        ))
        XCTAssertFalse(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://instance/i-123"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "soyeht://household/pair-device"))
        ))
    }

    /// THE MOUNTING, NOT THE HANDLER. `testClawShareInviteURLIsClaimedByTheDeepLinkMatcher`
    /// already proves the matcher claims this URL and the handler decodes it —
    /// and both passed while the guest experience was still broken, because
    /// nothing asserted that the flow owning that handler is ever presented.
    ///
    /// Measured on hardware 2026-08-12: a device with no household shows the
    /// onboarding flow the AppDelegate presents, `SSHLoginView` — the only
    /// consumer of `SessionStore.pendingDeepLink` — is never mounted, and the
    /// invite is stored and silently dropped. The person who was invited is
    /// asked "Where do you want to install Soyeht?" instead. Zero deep-link log
    /// lines on the guest across two independent deliveries.
    ///
    /// This is the routing half, and it is the half that was false.
    func testClawShareInviteOpensMainStoryboardSoAGuestWithNoHouseholdCanSeeIt() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertTrue(
            OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url),
            "an invited guest must reach the flow that consumes the invite, not the install picker"
        )
    }

    /// Routing must not depend on the invite being *good*, or the router would
    /// need its own decode — a second definition of "is this an invite" that
    /// can drift from `ClawShareURI.prefix` and reopen the bug above.
    ///
    /// The refusal still happens, one layer down and already covered by
    /// `testMalformedClawShareURLIsClaimedThenRefused`: the dispatcher rejects
    /// it and nothing is claimed or consumed. Routing decides WHICH flow reads
    /// the URL; it grants nothing.
    func testMalformedClawShareURLStillRoutesAndIsRefusedDownstreamNotHere() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url))
        switch QRScannerDispatcher.result(for: url, activeHouseholdId: nil, now: now) {
        case .success(let result):
            XCTFail("routing must not imply acceptance; got \(result)")
        case .failure:
            break
        }
    }

    // MARK: - Per-call-site teeth
    //
    // `shouldOpenMainStoryboard` alone is not enough: a mutant that deletes the
    // invite consideration from the COLD path (`willConnectTo`) or the WARM
    // path (`openURLContexts`) leaves a test of the predicate green. The two
    // decisions below are the values those call sites present, so removing the
    // invite handling from either one turns its own test RED.

    /// COLD LAUNCH. This is the exact shape that shipped broken: no household,
    /// so `hasSetupState` is false, and the invite must still win over Mac
    /// discovery. Without the invite branch this returns `.automaticMacDiscovery`
    /// — which is literally the "Where do you want to install Soyeht?" path the
    /// invited guest was dropped into.
    func testColdLaunchWithAnInviteAndNoHouseholdOpensMainNotMacDiscovery() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertEqual(
            OnboardingDeepLinkRouter.launchRoot(
                launchURL: url,
                restoredFromBackup: false,
                hasNoSetupState: true,
                carouselEnabled: true,
                shouldShowCarousel: true
            ),
            .mainStoryboard
        )
    }

    /// The same cold launch without an invite must keep onboarding, or every
    /// fresh install is ejected into a home it does not have.
    func testColdLaunchWithoutAnInviteKeepsOnboarding() {
        XCTAssertEqual(
            OnboardingDeepLinkRouter.launchRoot(
                launchURL: nil,
                restoredFromBackup: false,
                hasNoSetupState: true,
                carouselEnabled: true,
                shouldShowCarousel: true
            ),
            .automaticMacDiscovery
        )
    }

    /// A restore-from-backup outranks everything, invite included: the device
    /// has state to reconcile before it can act on anything.
    func testRestoredFromBackupOutranksAnInvite() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertEqual(
            OnboardingDeepLinkRouter.launchRoot(
                launchURL: url,
                restoredFromBackup: true,
                hasNoSetupState: true,
                carouselEnabled: true,
                shouldShowCarousel: true
            ),
            .restoredFromBackup
        )
    }

    /// THE ALREADY-A-HOUSEHOLD ARM. An owner who taps an invite must not be
    /// diverted into the carousel; the invite still reaches the dispatcher and
    /// sheet. Also pins that the carousel is what an ordinary launch gets, so
    /// this test fails if the invite branch stops outranking it.
    func testInviteOutranksTheCarouselOnADeviceThatAlreadyHasAHousehold() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertEqual(
            OnboardingDeepLinkRouter.launchRoot(
                launchURL: url,
                restoredFromBackup: false,
                hasNoSetupState: false,
                carouselEnabled: true,
                shouldShowCarousel: true
            ),
            .mainStoryboard
        )
        XCTAssertEqual(
            OnboardingDeepLinkRouter.launchRoot(
                launchURL: nil,
                restoredFromBackup: false,
                hasNoSetupState: false,
                carouselEnabled: true,
                shouldShowCarousel: true
            ),
            .carousel,
            "control: without an invite this launch is the carousel, so the case above is not vacuous"
        )
    }

    /// WARM DELIVERY, app already open on an onboarding screen — the other
    /// shape measured on hardware. The root must be swapped so the flow that
    /// consumes the invite exists.
    func testWarmInviteSwapsRootWhenNotAlreadyOnMain() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertTrue(
            OnboardingDeepLinkRouter.shouldSwapToMain(for: url, rootIsAlreadyMain: false)
        )
        XCTAssertFalse(
            OnboardingDeepLinkRouter.shouldSwapToMain(for: url, rootIsAlreadyMain: true),
            "already on main: rebuilding the root would tear down the very sheet we are about to show"
        )
    }

    /// And a warm non-invite must not move anyone.
    func testWarmNonInviteNeverSwapsRoot() throws {
        let url = try XCTUnwrap(URL(string: "theyos://instance/inst-123"))

        XCTAssertFalse(
            OnboardingDeepLinkRouter.shouldSwapToMain(for: url, rootIsAlreadyMain: false)
        )
    }

    /// The other half of the invariant: a device that is genuinely onboarding
    /// must keep onboarding. If this ever goes true, every fresh install gets
    /// ejected out of setup into a home it does not have yet.
    func testNonInviteURLsLeaveOnboardingUntouched() throws {
        // Deliberately excludes `soyeht://household/pair-machine`: whether that
        // shape should route during onboarding is a question this slice has not
        // investigated, and pinning it here would cement an answer either way.
        let untouched = [
            "theyos://instance/inst-123",
            "https://example.com/claw-share/v1?e=abc"
        ]
        for raw in untouched {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(
                OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url),
                "\(raw) must not eject a device out of onboarding"
            )
        }
    }

    // MARK: - Presentation gate: one sheet, one claim

    private let slotA = Data(repeating: 0xA1, count: 16)
    private let slotB = Data(repeating: 0xB2, count: 16)

    /// THE DOUBLE-DELIVERY THAT THE APP DELIBERATELY CREATES. The AppDelegate
    /// writes `pendingDeepLink` *and* posts `.soyehtDeepLink` for the same URL,
    /// on purpose, because foreground delivery can race subscriber setup. Both
    /// arrive; exactly one sheet may result, and no claim yet.
    func testSameInviteDeliveredTwicePresentsOnceAndClaimsNothing() {
        var gate = ClawShareInvitePresentation()

        XCTAssertEqual(gate.receive(slotID: slotA), .present)
        XCTAssertEqual(gate.receive(slotID: slotA), .ignoreDuplicate)

        XCTAssertEqual(gate.awaitingSlotID, slotA, "the second delivery must not lose the first")
        XCTAssertEqual(gate.state, .awaiting(slotID: slotA), "still awaiting: presenting is not claiming")
    }

    /// A double tap on the confirm button must not claim twice. The slot is
    /// consumed atomically server-side, so a second claim burns the invite and
    /// leaves the person with nothing to retry.
    func testDoubleConfirmClaimsExactlyOnce() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)

        XCTAssertTrue(gate.confirm(), "first confirm is the claim")
        XCTAssertFalse(gate.confirm(), "second confirm must produce no effect")
        XCTAssertEqual(gate.state, .opening(slotID: slotA))
    }

    /// Cancel claims nothing, and a confirm arriving afterwards claims nothing
    /// either — there is no invite under it any more.
    func testCancelClaimsNothingAndACancelledInviteCannotBeConfirmed() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)

        XCTAssertTrue(gate.cancel())
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.confirm(), "a cancelled invite must not be claimable")
    }

    /// A cancel that lands after confirm must not pretend the slot is unspent.
    /// The sheet dismissing is not evidence that nothing happened.
    func testCancelAfterConfirmDoesNotReopenASpentInvite() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)
        XCTAssertTrue(gate.confirm())

        XCTAssertFalse(gate.cancel(), "the claim is already in flight")
        XCTAssertEqual(gate.state, .opening(slotID: slotA))
    }

    /// IN-PROCESS REPLAY. `protectedDataDidBecomeAvailable` and the launch
    /// replay both re-post the same URL while the sheet is up. The invite must
    /// be neither lost nor duplicated.
    ///
    /// Scope, stated rather than implied: this is replay *within the process*.
    /// `pendingDeepLink` is not persisted, so a later relaunch without the OS
    /// re-delivering the URL is not covered here and is not claimed to be.
    func testInProcessReplayWhileAwaitingNeitherLosesNorDuplicates() {
        var gate = ClawShareInvitePresentation()
        XCTAssertEqual(gate.receive(slotID: slotA), .present)

        XCTAssertEqual(gate.receive(slotID: slotA), .ignoreDuplicate)
        XCTAssertEqual(gate.receive(slotID: slotA), .ignoreDuplicate)

        XCTAssertEqual(gate.awaitingSlotID, slotA)
        XCTAssertTrue(gate.confirm(), "the invite survived the replays and is still claimable exactly once")
        XCTAssertFalse(gate.confirm())
    }

    /// A genuinely different invite while merely awaiting replaces it: the
    /// person tapped a newer link and that is the one they mean.
    func testADifferentInviteWhileAwaitingReplacesTheOlderOne() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)

        XCTAssertEqual(gate.receive(slotID: slotB), .present)
        XCTAssertEqual(gate.awaitingSlotID, slotB)
    }

    /// A different invite mid-claim is DROPPED, and the result says so rather
    /// than calling it a duplicate — it is not one. Naming the loss is the
    /// point: `ignoreDuplicate` in the log would hide a real invite going
    /// nowhere behind a benign word.
    func testADifferentInviteMidClaimIsDroppedAndNamedAsSuchNotAsADuplicate() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)
        XCTAssertTrue(gate.confirm())

        XCTAssertEqual(
            gate.receive(slotID: slotB), .ignoredWhileOpening,
            "a genuinely different invite is lost here; the caller must be able to report that"
        )
        XCTAssertEqual(gate.state, .opening(slotID: slotA), "the in-flight claim keeps its own subject")
    }

    /// THE INTERLEAVED CASE, which is what makes "already attempted" mean
    /// anything. Holding only the most recently settled slot was still
    /// fail-open, and this is the exact sequence that showed it: settle A,
    /// then let another invite come and go, then replay A.
    ///
    /// With history kept only in the current state, receiving B replaced A and
    /// cancelling B cleared the lot, so A presented again and could be
    /// attempted a second time. A test that only replays A immediately after
    /// settling it cannot see that.
    func testAnAttemptedSlotStaysRefusedAcrossAnUnrelatedInviteComingAndGoing() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)
        XCTAssertTrue(gate.confirm())
        gate.finishAttempt()

        // An unrelated invite arrives, is shown, and is dismissed.
        XCTAssertEqual(gate.receive(slotID: slotB), .present)
        XCTAssertTrue(gate.cancel())
        XCTAssertEqual(gate.state, .idle)

        XCTAssertEqual(
            gate.receive(slotID: slotA), .ignoreDuplicate,
            "A was already attempted; another invite passing through must not amnesty it"
        )
        XCTAssertFalse(gate.confirm())
    }

    /// The same refusal must survive a second invite that is itself attempted,
    /// not merely cancelled — the other way the history could be clobbered.
    func testAnAttemptedSlotStaysRefusedAfterAnotherInviteIsAlsoAttempted() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)
        XCTAssertTrue(gate.confirm())
        gate.finishAttempt()

        XCTAssertEqual(gate.receive(slotID: slotB), .present)
        XCTAssertTrue(gate.confirm())
        gate.finishAttempt()

        XCTAssertEqual(gate.receive(slotID: slotA), .ignoreDuplicate, "A is still spent")
        XCTAssertEqual(gate.receive(slotID: slotB), .ignoreDuplicate, "and so is B")
    }

    /// Immediately after settling: the simplest case, kept as the floor.
    func testASettledInviteStaysRefusedWhileADifferentOneIsStillWelcome() {
        var gate = ClawShareInvitePresentation()
        _ = gate.receive(slotID: slotA)
        XCTAssertTrue(gate.confirm())
        gate.finishAttempt()

        XCTAssertEqual(
            gate.receive(slotID: slotA), .ignoreDuplicate,
            "a late delivery of an already-claimed invite must not present again"
        )
        XCTAssertFalse(gate.confirm(), "and it must not be claimable a second time")
        XCTAssertEqual(gate.state, .idle)
        XCTAssertTrue(gate.attemptedSlotIDs.contains(slotA))

        XCTAssertEqual(gate.receive(slotID: slotB), .present, "a genuinely new invite is still welcome")
    }

    // MARK: - The wiring the reducer tests cannot reach

    /// THE BOUNDARY THE VALUE TESTS DO NOT PROVE. Every test above exercises
    /// `ClawShareInvitePresentation` in isolation; none of them can see whether
    /// the sheet actually consults it. That gap is precisely the shape of both
    /// defects this branch exists to fix — a correct component nothing routes
    /// through — so it gets a tooth even though this target has no UI test
    /// harness.
    ///
    /// Structural, deliberately narrow, and anchored on
    /// `ClawShareInviteConfirmationSheet(` because it occurs exactly once;
    /// `onConfirm:`/`onCancel:` do not, and slicing on a repeated marker would
    /// silently read some other sheet. The window is closed at the next sheet.
    func testTheInviteSheetActionsAreWiredThroughTheGate() throws {
        let source = try iosSource("SSHLoginView.swift")
        XCTAssertEqual(
            source.components(separatedBy: "ClawShareInviteConfirmationSheet(").count - 1, 1,
            "anchor must stay unique or this test reads the wrong region"
        )

        let sheet = try slice(
            source,
            from: "ClawShareInviteConfirmationSheet(",
            to: ".sheet(isPresented: $showAddDeviceSheet)"
        )
        let confirmBody = try slice(sheet, from: "onConfirm: {", to: "onCancel: {")
        let cancelBody = String(sheet[(try XCTUnwrap(sheet.range(of: "onCancel: {"))).upperBound...])

        // The gate's ANSWER must govern the branch, not merely be called.
        // Presence and order alone stay green against
        // `_ = invitePresentation.confirm()` followed by the claim, which is
        // the fail-open worth pinning: the decision is computed and discarded.
        XCTAssertTrue(
            confirmBody.contains("guard invitePresentation.confirm() else { return }"),
            "the gate's result must control the branch; calling and ignoring it claims regardless"
        )

        // And the claim must not be reachable before that decision.
        let gate = try XCTUnwrap(
            confirmBody.range(of: "invitePresentation.confirm()"),
            "confirm must go through the gate, or a double tap claims twice"
        )
        let claim = try XCTUnwrap(
            confirmBody.range(of: "handleQRScanned"),
            "confirm is expected to reach the claim"
        )
        XCTAssertTrue(
            gate.lowerBound < claim.lowerBound,
            "the claim must be reachable only after the gate has decided"
        )
        XCTAssertTrue(
            confirmBody.contains("invitePresentation.finishAttempt()"),
            "the attempted slot must be recorded on the claim path, or a late replay attempts again"
        )

        // Cancel must release the gate and claim nothing.
        XCTAssertTrue(
            cancelBody.contains("invitePresentation.cancel()"),
            "cancel must release the gate, or the invite can never be presented again"
        )
        XCTAssertFalse(
            cancelBody.contains("handleQRScanned"),
            "cancelling must not claim"
        )
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }

    func testOnboardingLaunchIntentOpensQRScannerOnlyOnce() throws {
        let suiteName = "com.soyeht.tests.onboardingIntent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))

        OnboardingLaunchIntent.requestQRScanner(defaults: defaults)

        XCTAssertTrue(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))
        XCTAssertFalse(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))
    }

    private func makePairMachineURL(
        transport: PairMachineTransport
    ) throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let hostname = "mac-alpha.local"
        let platform = PairMachinePlatform.macos.rawValue
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-machine"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "m_pub", value: publicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "hostname", value: hostname),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "transport", value: transport.rawValue),
            URLQueryItem(name: "addr", value: transport == .tailscale ? "100.64.0.10:8443" : "mac-alpha.local:8443"),
            URLQueryItem(name: "challenge_sig", value: signature.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240)),
            URLQueryItem(
                name: "anchor_secret",
                value: Data(repeating: 0xCC, count: 32).soyehtBase64URLEncodedString()
            )
        ]
        return try XCTUnwrap(components.url)
    }

    private func makeClawShareInvite() throws -> ClawShareInvite {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let unsigned = ClawShareInvite(
            householdId: "hh-test",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: publicKey,
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "relay-alpha"),
            expiresAt: UInt64(now.timeIntervalSince1970) + 600,
            ownerEngineNpub: "npub1ownerengine",
            claimRelays: ["wss://relay.example"],
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let signature = try privateKey.signature(for: ClawShareCodec.canonicalInviteSigningBytes(unsigned)).rawRepresentation
        return ClawShareInvite(
            householdId: unsigned.householdId,
            ownerPersonId: unsigned.ownerPersonId,
            ownerPublicKey: unsigned.ownerPublicKey,
            clawId: unsigned.clawId,
            slotId: unsigned.slotId,
            transportHint: unsigned.transportHint,
            expiresAt: unsigned.expiresAt,
            ownerEngineNpub: unsigned.ownerEngineNpub,
            claimRelays: unsigned.claimRelays,
            ownerSignature: signature
        )
    }

    private func makePairDeviceURL() throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        let householdPublicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xBC, count: 32)
        let machineCertFingerprint = Data(repeating: 0xDE, count: 32)

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-device"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "hh_pub", value: householdPublicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240)),
            URLQueryItem(
                name: "m_cert_fp",
                value: machineCertFingerprint.soyehtBase64URLEncodedString()
            ),
            URLQueryItem(name: "crit", value: "m_cert_fp")
        ]
        return try XCTUnwrap(components.url)
    }
}
