import Foundation
import XCTest
@testable import SoyehtCore

final class PairingInvitationContractTests: XCTestCase {
    private let dev = PairingInstallIdentity(profile: "dev", bootstrapPort: 8101)
    private let release = PairingInstallIdentity(profile: "release", bootstrapPort: 8091)
    private let endpoint = URL(string: "http://100.64.0.10:8101")!

    private func payload(_ installation: PairingInstallIdentity?) throws -> SetupInvitationPayload {
        SetupInvitationPayload(token: try SetupInvitationToken(bytes: Data(repeating: 0x42, count: 32)),
            ownerDisplayName: "Owner", expiresAt: 2_524_608_000, iphoneApnsToken: nil,
            installation: installation)
    }

    func testProfileSurvivesJSONCBORAndTXTWithoutPortInference() throws {
        let original = try payload(dev)
        let decoded = try SetupInvitationPayload.decodeDirectEndpointData(original.directEndpointData())
        try decoded.requireInstallation(dev)
        XCTAssertThrowsError(try decoded.requireInstallation(release)) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMismatch)
        }
        guard case .map(let verify) = try HouseholdCBOR.decode(original.verifyData()) else {
            return XCTFail("Expected CBOR verify response")
        }
        XCTAssertEqual(try SetupInvitationPayload.decodeInstallation(verify["installation"]), dev)
        XCTAssertEqual(try original.txtRecordFields()["profile"], "dev")
        XCTAssertEqual(try original.txtRecordFields()["bootstrap_port"], "8101")
    }

    func testLegacyPayloadIsReadableButCannotAuthorizeAutomaticClaim() throws {
        let legacy = try payload(nil)
        let decoded = try SetupInvitationPayload.decodeDirectEndpointData(legacy.directEndpointData())
        XCTAssertNil(decoded.installation)
        XCTAssertThrowsError(try decoded.requireInstallation(dev)) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMissing)
        }
    }

    func testWrongProfileCannotNotifyEvenWithTheCorrectToken() throws {
        let invitation = try payload(dev)
        let claim = SetupInvitationDirectClaim(token: invitation.token, macEngineURL: endpoint,
                                               installation: release, event: .bootstrapClaimAccepted)
        XCTAssertThrowsError(try SetupInvitationDirectClaim.decode(
            claim.encodedData(), expectedToken: invitation.token, expectedInstallation: dev)) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMismatch)
        }
    }

    func testOldClaimResponseCannotInventAnAcceptanceTimestamp() throws {
        let old = HouseholdCBOR.encode(.map(["v": .unsigned(1), "iphone_endpoint": .text("device-alpha.local:8092")]))
        XCTAssertThrowsError(try SetupInvitationClaimClient.decode(old, expectedInstallation: dev))
    }

    func testReceiptCannotCrossProfiles() throws {
        let ack = HouseholdCBOR.encode(.map([
            "v": .unsigned(1), "accepted_at": .unsigned(1_800_000_000),
            "installation": SetupInvitationPayload.installationCBOR(release),
        ]))
        XCTAssertThrowsError(try SetupInvitationClaimClient.decode(ack, expectedInstallation: dev)) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMismatch)
        }
    }

    func testCallbackCannotClaimSuccessWithoutACeremonyAndListenerOffer() throws {
        let claim = SetupInvitationDirectClaim(token: try payload(dev).token, macEngineURL: endpoint,
                                               installation: dev, event: .bootstrapClaimAccepted)
        XCTAssertThrowsError(try claim.chooseAddress(expectedInstallation: dev)) {
            XCTAssertEqual($0 as? PairingAddressError, .noAvailableEndpoint)
        }
    }

    func testQRTransportKeepsCandidatesAndRejectsAnAmbiguousOffer() throws {
        let candidates = [PairingAddressCandidate(url: endpoint, transport: .tailnet,
            operations: [.firstOwner], availability: .listening, expiresAt: Date(timeIntervalSince1970: 2_524_608_000))]
        let offer = PairingAddressOffer(installation: dev, generation: "bind-generation", candidates: candidates)
        let uri = try PairingLinkAddresses.attaching(offer, to: URL(string: "soyeht://household/pair-device?v=1")!)
        XCTAssertEqual(try PairingLinkAddresses.offer(in: uri), offer)
        var components = try XCTUnwrap(URLComponents(url: uri, resolvingAgainstBaseURL: false))
        let duplicate = try XCTUnwrap(components.queryItems?.last)
        components.queryItems?.append(duplicate)
        XCTAssertThrowsError(try PairingLinkAddresses.offer(in: XCTUnwrap(components.url)))
    }

    func testTransportFailureKeepsTheStageAndAddressWithoutSecrets() {
        let url = URL(string: "http://user:password@192.168.1.20:8101/path?token=secret#private")!
        let failure = PairingAttemptFailure.capture(URLError(.cannotFindHost), stage: .confirm, endpoint: url)
        XCTAssertEqual(failure.cause, .network(.dns, domain: NSURLErrorDomain, code: URLError.cannotFindHost.rawValue))
        XCTAssertEqual(failure.endpoint?.absoluteString, "http://192.168.1.20:8101/path")
        XCTAssertTrue(failure.diagnostic.contains("confirm"))
        for secret in ["password", "token=", "secret", "private"] { XCTAssertFalse(failure.diagnostic.contains(secret)) }
    }

    func testVisibilityAcknowledgementCannotHideAMissingOrContradictoryDeadline() {
        for fields: [String: HouseholdCBORValue] in [
            ["v": .unsigned(1), "open": .bool(true)],
            ["v": .unsigned(1), "open": .bool(true), "expires_at_unix": .null],
            ["v": .unsigned(1), "open": .bool(false), "expires_at_unix": .unsigned(123)],
        ] {
            XCTAssertThrowsError(try BootstrapPairDeviceWindowClient.decodeAck(HouseholdCBOR.encode(.map(fields))))
        }
    }

    func testPlainHTTPFailuresKeepTheTransportStage() throws {
        for stage: PlainHTTPTransportError.Stage in [.connect, .send, .receive, .timeout, .waitingTimeout] {
            let failure = PairingAttemptFailure.capture(PlainHTTPTransportError(stage: stage, detail: nil),
                stage: .confirm, endpoint: endpoint)
            let kind: PairingAttemptFailure.NetworkCause = [.timeout, .waitingTimeout].contains(stage) ? .timeout : .connection
            XCTAssertEqual(failure.cause, .network(kind, domain: "PlainHTTP.\(stage.rawValue)", code: 0))
        }
        XCTAssertThrowsError(try PairingAttemptFailure.rethrow(
            PlainHTTPTransportError(stage: .cancelled, detail: nil), stage: .confirm, endpoint: endpoint)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCancellationRemainsControlFlow() {
        XCTAssertThrowsError(try PairingAttemptFailure.rethrow(URLError(.cancelled), stage: .poll, endpoint: endpoint)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
