#if canImport(AuthenticationServices)
import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Headless tests for `OwnerApprovalV2Orchestrator` (start → assert → approve),
/// with an injected authenticate seam (no live `ASAuthorization`) and a fake
/// transport behind a real `OwnerApprovalV2Client`. Proves: the server's opaque
/// challenge + options are forwarded byte-for-byte to the assertion; the envelope
/// echoes the server `context` + the assertion; rejects stay generic; a failed
/// assertion never reaches `approveV2`.
@Suite struct OwnerApprovalV2OrchestratorTests {
    private static let cborContentType = "application/cbor"

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(SHA256.hash(data: payload)) }
    }

    /// Captures cross-actor test state for the `@Sendable` transport + the
    /// `@MainActor` authenticate seam.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _authRequest: OwnerPasskeyAssertionRequest?
        private var _approveBody: Data?
        private var _approveCalled = false
        private var _authCalled = false

        func recordAuth(_ r: OwnerPasskeyAssertionRequest) { lock.lock(); _authRequest = r; _authCalled = true; lock.unlock() }
        func recordApprove(_ body: Data?) { lock.lock(); _approveBody = body; _approveCalled = true; lock.unlock() }
        var authRequest: OwnerPasskeyAssertionRequest? { lock.lock(); defer { lock.unlock() }; return _authRequest }
        var approveBody: Data? { lock.lock(); defer { lock.unlock() }; return _approveBody }
        var approveCalled: Bool { lock.lock(); defer { lock.unlock() }; return _approveCalled }
        var authCalled: Bool { lock.lock(); defer { lock.unlock() }; return _authCalled }
    }

    // MARK: fixtures

    private static func sampleContext() -> OwnerApprovalContextV2 {
        OwnerApprovalContextV2(
            op: .pairMachineApprove,
            householdID: "hh_test",
            ownerPersonID: "p_owner",
            cursor: 7,
            machineID: "m_test",
            capabilities: ["machine-cert", "shamir-2pc"],
            issuedAt: 1000,
            expiresAt: 1600,
            replayNonce: Data([0x33, 0x33, 0x33, 0x33])
        )
    }

    private static let sampleChallenge = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
    private static let sampleAllowCredID = Data([0x00, 0x01, 0x02, 0x80, 0xFF, 0x7F])
    private static let sampleRpId = "alpha.example.test"
    private static let sampleUserVerification = "required"
    private static let sampleChallengeID = "challenge-id-abc"

    private static func sampleAssertion() -> OwnerPasskeyAssertion {
        OwnerPasskeyAssertion(
            credentialID: Data([0xAA, 0xAA]),
            authenticatorData: Data([0xBB, 0xBB, 0xBB]),
            clientDataJSON: Data([0xCC]),
            signature: Data([0xDD, 0xDD, 0xDD, 0xDD]),
            userHandle: Data([0xEE])
        )
    }

    /// Build a server-shaped start-response (random challenge — NOT a digest).
    private static func startResponseBody() -> Data {
        let publicKey: [String: HouseholdCBORValue] = [
            "rpId": .text(sampleRpId),
            "challenge": .text(sampleChallenge.soyehtBase64URLEncodedString()),
            "userVerification": .text(sampleUserVerification),
            "allowCredentials": .array([
                .map([
                    "type": .text("public-key"),
                    "id": .text(sampleAllowCredID.soyehtBase64URLEncodedString()),
                ]),
            ]),
        ]
        return HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "challenge_id": .text(sampleChallengeID),
            "context": sampleContext().cborValue(),
            "options": .map(["publicKey": .map(publicKey)]),
        ]))
    }

    private static let errorEnvelope = HouseholdCBOR.encode(
        .map(["v": .unsigned(1), "error": .text("unauthenticated")])
    )

    /// Wire an orchestrator over a real client + fake transport + injected
    /// authenticate. `authError`, if set, is thrown by the seam.
    @MainActor
    private static func makeOrchestrator(
        startStatus: Int = 200,
        approveStatus: Int = 200,
        assertion: OwnerPasskeyAssertion? = nil,
        authError: Error? = nil,
        recorder: Recorder
    ) -> OwnerApprovalV2Orchestrator {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = OwnerApprovalV2Client(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                let path = req.url?.path ?? ""
                let isStart = path.hasSuffix("/approval-v2/start")
                let status = isStart ? startStatus : approveStatus
                let body: Data
                if isStart {
                    body = status == 200 ? startResponseBody() : errorEnvelope
                } else {
                    recorder.recordApprove(req.httpBody)
                    body = status == 200 ? HouseholdCBOR.encode(.map(["v": .unsigned(1)])) : errorEnvelope
                }
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": cborContentType]
                )!
                return (body, resp)
            }
        )
        let authenticate: OwnerApprovalV2Orchestrator.Authenticate = { request in
            recorder.recordAuth(request)
            if let authError { throw authError }
            return assertion ?? sampleAssertion()
        }
        return OwnerApprovalV2Orchestrator(client: client, authenticate: authenticate)
    }

    // MARK: tests

    /// Happy path: the submitted envelope echoes the server `context` exactly and
    /// carries the assertion returned by the seam.
    @Test @MainActor func happyPathSubmitsEnvelopeWithServerContextAndAssertion() async throws {
        let recorder = Recorder()
        let assertion = Self.sampleAssertion()
        let orchestrator = Self.makeOrchestrator(assertion: assertion, recorder: recorder)

        try await orchestrator.approve(cursor: 7)

        let expected = OwnerApprovalV2Finish(
            challengeID: Self.sampleChallengeID,
            approval: OwnerApprovalV2(
                context: Self.sampleContext(),
                credentialID: assertion.credentialID,
                authenticatorData: assertion.authenticatorData,
                clientDataJSON: assertion.clientDataJSON,
                signature: assertion.signature,
                userHandle: assertion.userHandle
            )
        ).canonicalBytes()
        #expect(recorder.approveBody == expected)
    }

    /// The server's opaque challenge + options are forwarded byte-for-byte to the
    /// assertion request — no recompute/substitution.
    @Test @MainActor func forwardsOpaqueChallengeAndOptionsToAuthenticate() async throws {
        let recorder = Recorder()
        let orchestrator = Self.makeOrchestrator(recorder: recorder)

        try await orchestrator.approve(cursor: 7)

        let request = try #require(recorder.authRequest)
        #expect(request.challenge == Self.sampleChallenge)  // byte-for-byte
        #expect(request.relyingPartyIdentifier == Self.sampleRpId)
        #expect(request.allowedCredentialIDs == [Self.sampleAllowCredID])
        #expect(request.userVerification == Self.sampleUserVerification)
    }

    /// A `start` reject surfaces as the generic `BootstrapError`; the assertion is
    /// never attempted.
    @Test @MainActor func startRejectPropagatesGenericErrorWithoutAuthenticating() async {
        let recorder = Recorder()
        let orchestrator = Self.makeOrchestrator(startStatus: 401, recorder: recorder)

        await Self.expectServerError { try await orchestrator.approve(cursor: 7) }
        #expect(recorder.authCalled == false)
        #expect(recorder.approveCalled == false)
    }

    /// An `approve` reject (after a good assertion) surfaces as the generic
    /// `BootstrapError`.
    @Test @MainActor func approveRejectPropagatesGenericError() async {
        let recorder = Recorder()
        let orchestrator = Self.makeOrchestrator(approveStatus: 401, recorder: recorder)

        await Self.expectServerError { try await orchestrator.approve(cursor: 7) }
        #expect(recorder.authCalled == true)
        #expect(recorder.approveCalled == true)  // the request was sent; the server rejected
    }

    /// A cancelled/failed assertion propagates unchanged (not a network error) and
    /// `approveV2` is never called.
    @Test @MainActor func authenticateErrorPropagatesAndApproveNotCalled() async {
        let recorder = Recorder()
        let orchestrator = Self.makeOrchestrator(
            authError: OwnerPasskeyRegistrationError.canceled,
            recorder: recorder
        )

        do {
            try await orchestrator.approve(cursor: 7)
            Issue.record("expected the assertion error to propagate")
        } catch let error as OwnerPasskeyRegistrationError {
            #expect(error == .canceled)
        } catch {
            Issue.record("expected OwnerPasskeyRegistrationError, got \(error)")
        }
        #expect(recorder.approveCalled == false)
    }

    private static func expectServerError(_ op: () async throws -> Void) async {
        do {
            try await op()
            Issue.record("expected a throw on reject")
        } catch let error as BootstrapError {
            guard case .serverError(let code, let message) = error else {
                Issue.record("expected .serverError, got \(error)")
                return
            }
            #expect(code == "unauthenticated")
            #expect(message == nil)
        } catch {
            Issue.record("expected BootstrapError, got \(error)")
        }
    }
}
#endif
