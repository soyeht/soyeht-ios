import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// Behavioural contract for `RosterAlertPresentation`.
///
/// The banner is the only thing the roster ever says to a user, so two
/// properties matter more than the copy: exactly which coordinator states
/// interrupt them, and that nothing from the roster's payload can ride along.
///
/// **Coverage honesty.** `.current` and `.terminalFork` carry a
/// `VerifiedRosterProjection`, whose initializer is internal to `SoyehtCore`
/// and therefore not constructible from this target — the store is the only
/// producer, by design. Those two states are covered here by a compile-time
/// exhaustiveness witness (`expectedPresentation(for:)`) rather than by a
/// value-level assertion, and by the comment-stripped source guard in
/// `DevicePairApprovalPresentationTests`, which reads `resolve`'s own source and
/// requires both cases to appear in the branch that returns nil. Neither
/// substitutes for constructing the value; both are stated plainly rather than
/// hidden behind a green check.
final class RosterAlertPresentationTests: XCTestCase {
    /// A distinctive string planted in every payload that can hold one. If it
    /// ever appears in a resolved presentation, some associated value survived
    /// the resolution.
    private static let leakMarker = "m_secret_marker"

    // MARK: - Exhaustive case-count witness

    /// EXHAUSTIVE ON PURPOSE — no `default`. This mirrors `resolve` so that a
    /// seventh `RosterCoordinatorState` case breaks the TEST build too, not
    /// only the production build. It proves the case set, not the production
    /// mapping: the value-level assertions below are what check `resolve`
    /// itself, for every state this target can construct.
    private static func expectedPresentation(
        for state: RosterCoordinatorState
    ) -> RosterAlertPresentation? {
        switch state {
        case .unknown:
            return nil
        case .current:
            return nil
        case .degraded:
            return nil
        case .terminalFork:
            return nil
        case .requiresRePairing:
            return .rePairRequired
        case .tamperSuspected:
            return .unverifiable
        }
    }

    /// Every state this target can build, each one also run through the witness
    /// above so the two mappings cannot drift apart.
    private static var constructibleStates: [RosterCoordinatorState] {
        var states: [RosterCoordinatorState] = [.unknown]
        states.append(contentsOf: degradedStates)
        states.append(.requiresRePairing(retiredMId: leakMarker))
        states.append(contentsOf: tamperStates)
        return states
    }

    /// Every `RosterDegradedReason`, spelled out rather than derived, so adding
    /// a reason to the enum leaves a visible gap here.
    private static var degradedStates: [RosterCoordinatorState] {
        [
            .degraded(reason: .engine(outcome: leakMarker), lastKnown: nil),
            .degraded(reason: .engine(outcome: "unavailable_clock_state"), lastKnown: nil),
            .degraded(reason: .engine(outcome: "unavailable_owner_authority"), lastKnown: nil),
            .degraded(reason: .engine(outcome: "unavailable_checkpoint_stale"), lastKnown: nil),
            .degraded(reason: .transport, lastKnown: nil),
            .degraded(reason: .storage, lastKnown: nil),
        ]
    }

    /// Every `RosterTamperCategory`, including one of each nested error enum.
    private static var tamperStates: [RosterCoordinatorState] {
        [
            .tamperSuspected(.storedStateRejected(.blobUnreadable)),
            .tamperSuspected(.storedStateRejected(.versionUnsupported)),
            .tamperSuspected(.storedStateRejected(.householdMismatch)),
            .tamperSuspected(.storedStateRejected(.halfState)),
            .tamperSuspected(.storedStateRejected(.authorityRejected)),
            .tamperSuspected(.evidence(.nonceMismatch)),
            .tamperSuspected(.evidence(.certBindingInvalid)),
            .tamperSuspected(.evidence(.fingerprintMismatch)),
            .tamperSuspected(.evidence(.signatureInvalid)),
            .tamperSuspected(.evidence(.snapshotKeySetInvalid)),
            .tamperSuspected(.evidence(.digestMismatch)),
            .tamperSuspected(.evidence(.transitionInvalid)),
            .tamperSuspected(.evidence(.unavailableNeverPersists)),
            .tamperSuspected(.evidence(.anchorMismatch)),
            .tamperSuspected(.authority(.schemaInvalid)),
            .tamperSuspected(.authority(.canonicalMismatch)),
            .tamperSuspected(.authority(.rootSignatureInvalid)),
            .tamperSuspected(.authority(.ownerSignatureInvalid)),
            .tamperSuspected(.authority(.ownerCertInvalid)),
            .tamperSuspected(.authority(.ownerProvenanceInvalid)),
            .tamperSuspected(.authority(.ownerCaveatsInvalid)),
            .tamperSuspected(.authority(.householdMismatch)),
            .tamperSuspected(.authority(.epochMismatch)),
            .tamperSuspected(.authority(.sequenceInvalid)),
            .tamperSuspected(.authority(.hashChainInvalid)),
            .tamperSuspected(.authority(.eventPrefixInvalid)),
            .tamperSuspected(.authority(.duplicateMember)),
            .tamperSuspected(.authority(.memberSortInvalid)),
            .tamperSuspected(.authority(.tombstoneConflict)),
            .tamperSuspected(.authority(.temporalInvalid)),
            .tamperSuspected(.authority(.forkTerminal)),
            .tamperSuspected(.authority(.keySetInvalid)),
            .tamperSuspected(.malformed),
            .tamperSuspected(.anchorUnproven),
            .tamperSuspected(.storeRefusedCandidate),
        ]
    }

    // MARK: - Silence

    /// `.unknown` is the state every device sits in before the roster step has
    /// ever run — including when no activator is injected at all. Alarming on it
    /// would put a permanent warning on healthy devices.
    func test_unknownShowsNoBanner() {
        XCTAssertNil(RosterAlertPresentation.resolve(.unknown))
    }

    /// Degraded is retryable and never touches persistence, so it is
    /// operational noise rather than something to interrupt the user about.
    /// Every reason, including each attested engine outcome, stays silent.
    func test_everyDegradedReasonShowsNoBanner() {
        for state in Self.degradedStates {
            XCTAssertNil(
                RosterAlertPresentation.resolve(state),
                "degraded must stay silent: \(String(describing: state))"
            )
        }
    }

    // MARK: - Visible

    func test_requiresRePairingShowsRePairBanner() {
        XCTAssertEqual(
            RosterAlertPresentation.resolve(.requiresRePairing(retiredMId: Self.leakMarker)),
            .rePairRequired
        )
    }

    /// Every tamper category resolves to the same, single presentation. The
    /// categories differ in what failed; none of that difference is safe to
    /// show, and collapsing them here is what keeps the view from having a
    /// reason to inspect the payload.
    func test_everyTamperCategoryShowsUnverifiableBanner() {
        for state in Self.tamperStates {
            XCTAssertEqual(
                RosterAlertPresentation.resolve(state),
                .unverifiable,
                "tamper must be unverifiable: \(String(describing: state))"
            )
        }
    }

    /// Exactly two states interrupt the user, and they are the two that are
    /// either actionable or untrustworthy. Counted over every state this target
    /// can construct, so a future state that starts resolving to a banner shows
    /// up here as a count change.
    func test_onlyRePairingAndTamperAreVisible() {
        let visible = Self.constructibleStates.filter {
            RosterAlertPresentation.resolve($0) != nil
        }
        XCTAssertEqual(visible.count, 1 + Self.tamperStates.count)
        for state in visible {
            switch RosterAlertPresentation.resolve(state) {
            case .rePairRequired, .unverifiable:
                break
            case nil:
                XCTFail("filtered state resolved to nil: \(String(describing: state))")
            }
        }
    }

    // MARK: - Witness agreement

    /// Every constructible state agrees with the exhaustive witness. The
    /// witness is what makes a seventh coordinator case a build break in this
    /// target; this test is what stops the witness from silently disagreeing
    /// with production.
    func test_resolveAgreesWithExhaustiveWitness() {
        for state in Self.constructibleStates {
            XCTAssertEqual(
                RosterAlertPresentation.resolve(state),
                Self.expectedPresentation(for: state),
                "resolve disagreed with the witness for \(String(describing: state))"
            )
        }
    }

    // MARK: - Call to action

    /// The re-pair state is the only one the coordinator reaches by verifying an
    /// owner-signed revocation, so it is the only one allowed to offer an
    /// action. Offering re-pairing from `.unverifiable` would hand an attacker
    /// who can provoke an unproven anchor mismatch the exact prompt the
    /// coordinator refuses to produce.
    func test_onlyRePairRequiredOffersASettingsAction() {
        XCTAssertTrue(RosterAlertPresentation.rePairRequired.offersSettingsAction)
        XCTAssertFalse(RosterAlertPresentation.unverifiable.offersSettingsAction)
    }

    // MARK: - Identity gate

    /// The named failure this gate exists for: a roster state left over from a
    /// previous session must not paint a banner once the identity is gone.
    ///
    /// Today `stop()` also publishes `.unknown`, which would hide the banner
    /// anyway — which is exactly why this is asserted against the *stale*
    /// alerting states rather than against `.unknown`. The gate has to hold on
    /// its own, so a teardown change that stopped clearing `rosterState` cannot
    /// resurrect the banner without failing here.
    func test_staleAlertingStateShowsNoBannerWhenIdentityIsInactive() {
        let stale: [RosterCoordinatorState] = [
            .requiresRePairing(retiredMId: Self.leakMarker),
            .tamperSuspected(.anchorUnproven),
            .tamperSuspected(.evidence(.signatureInvalid)),
            .tamperSuspected(.storedStateRejected(.householdMismatch)),
        ]
        for state in stale {
            XCTAssertNotNil(
                RosterAlertPresentation.resolve(state),
                "fixture must be a state that WOULD alarm an active identity: \(String(describing: state))"
            )
            XCTAssertNil(
                RosterAlertPresentation.resolve(state, identityActive: false),
                "no active identity means no home to speak about: \(String(describing: state))"
            )
        }
    }

    /// Every state this target can construct, not only the alerting ones: with
    /// no active identity the gate is total.
    func test_inactiveIdentitySilencesEveryConstructibleState() {
        for state in Self.constructibleStates {
            XCTAssertNil(
                RosterAlertPresentation.resolve(state, identityActive: false),
                "inactive identity must silence \(String(describing: state))"
            )
        }
    }

    /// The gate only gates. With an active identity the decision must be
    /// identical to the ungated resolution, or the two surfaces would start
    /// disagreeing with the exhaustive mapping tested above.
    func test_activeIdentityPreservesTheUngatedResolution() {
        for state in Self.constructibleStates {
            XCTAssertEqual(
                RosterAlertPresentation.resolve(state, identityActive: true),
                RosterAlertPresentation.resolve(state),
                "the identity gate must not change the mapping for \(String(describing: state))"
            )
            XCTAssertEqual(
                RosterAlertPresentation.resolve(state, identityActive: true),
                Self.expectedPresentation(for: state)
            )
        }
    }

    /// Non-vacuity for the pair above: the gated and ungated results must
    /// actually differ somewhere, otherwise `identityActive` could be ignored
    /// entirely and every assertion here would still pass.
    func test_identityGateChangesTheOutcomeForAlertingStates() {
        let alerting = Self.constructibleStates.filter {
            RosterAlertPresentation.resolve($0) != nil
        }
        XCTAssertFalse(alerting.isEmpty)
        for state in alerting {
            XCTAssertNotEqual(
                RosterAlertPresentation.resolve(state, identityActive: false),
                RosterAlertPresentation.resolve(state, identityActive: true),
                "the gate must be load-bearing for \(String(describing: state))"
            )
        }
    }

    // MARK: - Leak

    /// The payload of every state that can hold a string carries `leakMarker`.
    /// If the resolved presentation's description contains it, some associated
    /// value survived resolution — which is the whole failure mode the dataless
    /// enum exists to make impossible.
    func test_resolvedPresentationCarriesNoPayloadFromTheState() {
        let carriers: [RosterCoordinatorState] = [
            .requiresRePairing(retiredMId: Self.leakMarker),
            .degraded(reason: .engine(outcome: Self.leakMarker), lastKnown: nil),
        ]
        for state in carriers {
            XCTAssertTrue(
                String(describing: state).contains(Self.leakMarker),
                "fixture is not exercising the leak path: \(String(describing: state))"
            )
            let described = String(describing: RosterAlertPresentation.resolve(state))
            XCTAssertFalse(
                described.contains(Self.leakMarker),
                "resolved presentation leaked payload: \(described)"
            )
        }

        // And no presentation value can ever describe itself with a payload,
        // regardless of which state produced it.
        for presentation in [RosterAlertPresentation.rePairRequired, .unverifiable] {
            XCTAssertFalse(String(describing: presentation).contains(Self.leakMarker))
            XCTAssertFalse(String(reflecting: presentation).contains(Self.leakMarker))
        }
    }

    /// Equality ignores nothing, because there is nothing to ignore: two
    /// presentations resolved from states with different payloads are the same
    /// value. This is the property that lets SwiftUI diff the banner without
    /// ever seeing roster material.
    func test_presentationsFromDifferentPayloadsAreEqual() {
        XCTAssertEqual(
            RosterAlertPresentation.resolve(.requiresRePairing(retiredMId: Self.leakMarker)),
            RosterAlertPresentation.resolve(.requiresRePairing(retiredMId: "m_alpha"))
        )
        XCTAssertEqual(
            RosterAlertPresentation.resolve(.tamperSuspected(.anchorUnproven)),
            RosterAlertPresentation.resolve(.tamperSuspected(.evidence(.signatureInvalid)))
        )
        XCTAssertNotEqual(RosterAlertPresentation.rePairRequired, .unverifiable)
    }
}
