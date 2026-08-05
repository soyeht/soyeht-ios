import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import XCTest

@testable import Soyeht

final class ClawShareOpenFailureTests: XCTestCase {
    func test_inviteExpiredMapsToLinkExpiredWithAskForNewLink() {
        XCTAssertEqual(ClawShareOpenFailure.classify(ClawShareError.inviteExpired), .linkExpired)
        XCTAssertEqual(ClawShareOpenFailure.linkExpired.nextAction, .askForNewLink)
    }

    func test_credentialExpiredAlsoMapsToLinkExpired() {
        XCTAssertEqual(ClawShareOpenFailure.classify(ClawShareError.credentialExpired), .linkExpired)
    }

    func test_rejectionAndMismatchCausesMapToLinkNoLongerValid() {
        // These cannot be told apart by the client today (no server code on
        // the wire distinguishes revoked from already-consumed from a
        // generic rejection) — grouping them, not fabricating precision the
        // client doesn't have, is the point of this test.
        let causes: [ClawShareError] = [
            .inviteMalformed,
            .inviteSignatureRejected,
            .claimSignatureRejected,
            .credentialSignatureRejected,
            .credentialIssuerMismatch,
            .credentialClawMismatch,
            .credentialGuestMismatch,
            .credentialSlotMismatch,
            .relayStreamOfferRejected,
            .groupDeviceKeyMismatch,
            .groupChallengeMismatch,
            .serverRejected(code: "whatever", message: nil),
        ]

        for cause in causes {
            XCTAssertEqual(
                ClawShareOpenFailure.classify(cause), .linkNoLongerValid,
                "\(cause) should classify as linkNoLongerValid"
            )
        }
        XCTAssertEqual(ClawShareOpenFailure.linkNoLongerValid.nextAction, .askForNewLink)
    }

    func test_transportCausesMapToTemporaryConnectionFailureWithRetry() {
        XCTAssertEqual(ClawShareOpenFailure.classify(ClawShareError.transportClosed), .temporaryConnectionFailure)
        XCTAssertEqual(ClawShareOpenFailure.classify(ClawShareError.ackTimedOut), .temporaryConnectionFailure)
        XCTAssertEqual(ClawShareOpenFailure.temporaryConnectionFailure.nextAction, .retry)
    }

    func test_unexpectedFrameMapsToIncompatibleClientWithClose() {
        XCTAssertEqual(ClawShareOpenFailure.classify(ClawShareError.unexpectedFrame), .incompatibleClient)
        XCTAssertEqual(ClawShareOpenFailure.incompatibleClient.nextAction, .close)
    }

    func test_routeErrorMissingOfferMapsToLinkNoLongerValid() {
        XCTAssertEqual(
            ClawShareOpenFailure.classify(ClawShareOpenRouter.RouteError.missingRelayStreamOffer),
            .linkNoLongerValid
        )
    }

    func test_routeErrorUnsupportedResourceMapsToIncompatibleClient() {
        XCTAssertEqual(
            ClawShareOpenFailure.classify(ClawShareOpenRouter.RouteError.unsupportedResource(.ipTunnel)),
            .incompatibleClient
        )
    }

    private struct SomeOtherError: Error {}

    func test_anUnrecognizedErrorDefaultsToUnknownWithRetry() {
        // Retry, not a dead end, is the least presumptuous default for a
        // cause this classifier does not recognize by type.
        XCTAssertEqual(ClawShareOpenFailure.classify(SomeOtherError()), .unknown)
        XCTAssertEqual(ClawShareOpenFailure.unknown.nextAction, .retry)
    }

    // MARK: - Tunnel reason matching (4B-2-3)
    //
    // The engine sends `TunnelFrame::Error(e.to_string())`; for
    // `DataTunnelError::TargetUnavailable(code)` that renders as
    // "target service unavailable: {code}" — the code is never the whole
    // message. These pin the matcher against the REAL shape plus the
    // adversarial shapes a loose `contains`/prefix check would wrongly
    // accept.

    func test_tunnelReasonMatchesTheRealPrefixedPayload() {
        XCTAssertTrue(ClawSiteTunnelReason.message(
            "target service unavailable: relay-stream-share-app-unavailable",
            matches: ClawSiteTunnelReason.shareAppUnavailable
        ))
    }

    func test_tunnelReasonMatchesTheBareCode() {
        // Defensive: not the shape the engine sends today, but a stable
        // code standing alone must still be recognized.
        XCTAssertTrue(ClawSiteTunnelReason.message(
            ClawSiteTunnelReason.shareAppUnavailable,
            matches: ClawSiteTunnelReason.shareAppUnavailable
        ))
    }

    func test_tunnelReasonRejectsAnExtendedSuffix() {
        // A different, longer code that happens to start with ours must
        // not false-positive under a naive `contains`/prefix check.
        XCTAssertFalse(ClawSiteTunnelReason.message(
            "target service unavailable: relay-stream-share-app-unavailable-extended",
            matches: ClawSiteTunnelReason.shareAppUnavailable
        ))
    }

    func test_tunnelReasonRejectsTheCodeBeforeTheWrongDelimiter() {
        XCTAssertFalse(ClawSiteTunnelReason.message(
            "relay-stream-share-app-unavailable: target service unavailable",
            matches: ClawSiteTunnelReason.shareAppUnavailable
        ))
    }

    func test_tunnelReasonRejectsTheCodeGluedWithoutADelimiter() {
        XCTAssertFalse(ClawSiteTunnelReason.message(
            "foo-relay-stream-share-app-unavailable",
            matches: ClawSiteTunnelReason.shareAppUnavailable
        ))
    }

    func test_shareAppUnavailableReasonIsRecognizedAsRecoverable() {
        let error = RelayStreamGuestError.AuthRejected(
            "target service unavailable: relay-stream-share-app-unavailable"
        )
        XCTAssertTrue(ClawShareOpenFailure.isRecoverableAppUnavailable(error))
    }

    func test_shareAppNoLongerAvailableReasonMapsToLinkNoLongerValid() {
        let error = RelayStreamGuestError.AuthRejected(
            "target service unavailable: relay-stream-share-app-no-longer-available"
        )
        XCTAssertFalse(ClawShareOpenFailure.isRecoverableAppUnavailable(error))
        XCTAssertEqual(ClawShareOpenFailure.classify(error), .linkNoLongerValid)
    }

    func test_unrelatedTunnelReasonFallsBackToUnknown() {
        let error = RelayStreamGuestError.AuthRejected("target service unavailable: relay-stream-slot-revoked")
        XCTAssertFalse(ClawShareOpenFailure.isRecoverableAppUnavailable(error))
        XCTAssertEqual(ClawShareOpenFailure.classify(error), .unknown)
    }

    func test_streamFailedCarriesTheReasonThroughTheSameMatcher() {
        // The mid-stream-frame path loses the FFI type but keeps the text —
        // must classify identically to the AuthRejected path above.
        let error = ClawSiteBridgeError.streamFailed(
            "target service unavailable: relay-stream-share-app-unavailable"
        )
        XCTAssertTrue(ClawShareOpenFailure.isRecoverableAppUnavailable(error))
    }

    func test_everyCaseHasNonEmptyTitleAndMessage() {
        let cases: [ClawShareOpenFailure] = [
            .linkExpired, .linkNoLongerValid, .temporaryConnectionFailure, .incompatibleClient, .unknown,
        ]
        for failure in cases {
            XCTAssertFalse(failure.title.isEmpty, "\(failure) must have a non-empty title")
            XCTAssertFalse(failure.message.isEmpty, "\(failure) must have a non-empty message")
        }
    }
}
