#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
import Testing

@testable import SoyehtCore

/// Unit tests for the app-target-free seams of ``PasskeyProvider``: request
/// construction and error mapping. The live ASAuthorization ceremony needs a
/// real authenticator + window + entitlement and is exercised manually on a
/// device target (S3c), not here.
@Suite struct PasskeyProviderTests {
    // MARK: makeRegistrationRequest field propagation

    @Test func makeRegistrationRequestPropagatesStandardFields() {
        let challenge = Data([0x01, 0x02, 0x03, 0x04])
        let userID = Data("owner-person-id".utf8)
        let request = OwnerPasskeyRegistrationRequest(
            relyingPartyIdentifier: "household.example",
            challenge: challenge,
            userID: userID,
            userName: "owner",
            userDisplayName: "Owner"
        )

        let asRequest = PasskeyProvider.makeRegistrationRequest(request)

        #expect(asRequest.relyingPartyIdentifier == "household.example")
        #expect(asRequest.challenge == challenge)
        #expect(asRequest.userID == userID)
        #expect(asRequest.name == "owner")
    }

    // MARK: error mapping

    @Test func mapsCanceledError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.canceled)) == .canceled)
    }

    @Test func mapsNotHandledError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.notHandled)) == .notHandled)
    }

    @Test func mapsInvalidResponseError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.invalidResponse)) == .invalidResponse)
    }

    @Test func mapsFailedErrorToFailedCase() {
        guard case .failed = PasskeyProvider.map(ASAuthorizationError(.failed)) else {
            Issue.record("expected .failed for ASAuthorizationError(.failed)")
            return
        }
    }

    @Test func mapsNonAuthServicesErrorToUnknown() {
        let error = NSError(
            domain: "test.passkey",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        guard case .unknown = PasskeyProvider.map(error) else {
            Issue.record("expected .unknown for a non-ASAuthorizationError")
            return
        }
    }

    // MARK: value-type round trips

    @Test func attestationIsValueEquatable() {
        let a = OwnerPasskeyAttestation(
            credentialID: Data([0x10]),
            attestationObject: Data([0x20]),
            clientDataJSON: Data([0x30])
        )
        let b = OwnerPasskeyAttestation(
            credentialID: Data([0x10]),
            attestationObject: Data([0x20]),
            clientDataJSON: Data([0x30])
        )
        #expect(a == b)
    }
}
#endif
