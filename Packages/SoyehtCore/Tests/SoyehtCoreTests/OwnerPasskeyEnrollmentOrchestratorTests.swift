#if canImport(AuthenticationServices)
import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Headless tests for `OwnerPasskeyEnrollmentOrchestrator` (start → register →
/// finish), with an injected register seam (no live `ASAuthorization`) and a fake
/// transport behind a real `OwnerPasskeyEnrollmentClient`. Proves: register gets
/// the request derived from the start response; finish gets the start
/// `challengeID` + the credential derived from the attestation; fail-closed
/// ordering; generic rejects.
@Suite struct OwnerPasskeyEnrollmentOrchestratorTests {
    private static let cborContentType = "application/cbor"

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(SHA256.hash(data: payload)) }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _registerRequest: OwnerPasskeyRegistrationRequest?
        private var _finishBody: Data?
        private var _registerCalled = false
        private var _finishCalled = false

        func recordRegister(_ r: OwnerPasskeyRegistrationRequest) { lock.lock(); _registerRequest = r; _registerCalled = true; lock.unlock() }
        func recordFinish(_ body: Data?) { lock.lock(); _finishBody = body; _finishCalled = true; lock.unlock() }
        var registerRequest: OwnerPasskeyRegistrationRequest? { lock.lock(); defer { lock.unlock() }; return _registerRequest }
        var finishBody: Data? { lock.lock(); defer { lock.unlock() }; return _finishBody }
        var registerCalled: Bool { lock.lock(); defer { lock.unlock() }; return _registerCalled }
        var finishCalled: Bool { lock.lock(); defer { lock.unlock() }; return _finishCalled }
    }

    // MARK: fixtures (real registration wire vectors)

    enum FixtureError: Error { case missing }

    private static func registrationVectors() throws -> (startHex: String, finishHex: String) {
        struct Vectors: Decodable {
            let startResponses: [Case]
            let finishResponses: [Case]
        }
        struct Case: Decodable { let canonicalCborHex: String }
        guard let url = Bundle.module.url(forResource: "owner_webauthn_registration_vectors", withExtension: "json") else {
            throw FixtureError.missing
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let v = try decoder.decode(Vectors.self, from: try Data(contentsOf: url))
        return (v.startResponses[0].canonicalCborHex, v.finishResponses[0].canonicalCborHex)
    }

    private static func sampleAttestation() -> OwnerPasskeyAttestation {
        OwnerPasskeyAttestation(
            credentialID: Data([0x11, 0x22, 0x33]),
            attestationObject: Data([0xA0, 0xA1]),
            clientDataJSON: Data([0xB0])
        )
    }

    /// Wire an orchestrator over a real client + fake transport + injected register.
    @MainActor
    private static func makeOrchestrator(
        startStatus: Int = 200,
        finishStatus: Int = 200,
        attestation: OwnerPasskeyAttestation? = nil,
        registerError: Error? = nil,
        recorder: Recorder
    ) throws -> OwnerPasskeyEnrollmentOrchestrator {
        let (startHex, finishHex) = try registrationVectors()
        let startBody = hexDecode(startHex)
        let finishBody = hexDecode(finishHex)
        let errorEnvelope = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))

        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = OwnerPasskeyEnrollmentClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                let path = req.url?.path ?? ""
                let isStart = path.hasSuffix("/registration/start")
                let status = isStart ? startStatus : finishStatus
                let body: Data
                if isStart {
                    body = status == 200 ? startBody : errorEnvelope
                } else {
                    recorder.recordFinish(req.httpBody)
                    body = status == 200 ? finishBody : errorEnvelope
                }
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": cborContentType]
                )!
                return (body, resp)
            }
        )
        let register: OwnerPasskeyEnrollmentOrchestrator.Register = { request in
            recorder.recordRegister(request)
            if let registerError { throw registerError }
            return attestation ?? sampleAttestation()
        }
        return OwnerPasskeyEnrollmentOrchestrator(client: client, register: register)
    }

    // MARK: tests

    /// Happy path: register receives the request derived from the start response;
    /// finish receives the start `challengeID` + the credential derived from the
    /// attestation; the result is returned.
    @Test @MainActor func happyPathWiresStartRegisterFinish() async throws {
        let recorder = Recorder()
        let attestation = Self.sampleAttestation()
        let orchestrator = try Self.makeOrchestrator(attestation: attestation, recorder: recorder)

        let result = try await orchestrator.enroll()

        // register got the request derived from the (decoded) start response.
        let (startHex, _) = try Self.registrationVectors()
        let startResponse = try OwnerWebauthnRegistrationStartResponse(
            cbor: HouseholdCBOR.decode(Self.hexDecode(startHex))
        )
        let expectedRequest = try OwnerPasskeyEnrollmentClient.registrationRequest(from: startResponse)
        #expect(recorder.registerRequest == expectedRequest)

        // finish got the start challengeID + the exact credential from the attestation.
        let expectedFinish = OwnerWebauthnRegistrationFinishRequest(
            version: OwnerWebauthnRegistrationStartRequest.currentVersion,
            challengeID: startResponse.challengeID,
            credential: OwnerPasskeyEnrollmentClient.credential(from: attestation)
        ).canonicalBytes()
        #expect(recorder.finishBody == expectedFinish)

        // result decoded from the finish response (credential_id byte-string).
        #expect(result.credentialID == Data([0x00, 0x01, 0x02, 0x80, 0xFF, 0x7F]))
    }

    /// A `start` reject propagates as a generic error and the ceremony never runs.
    @Test @MainActor func startRejectPropagatesWithoutRegisterOrFinish() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(startStatus: 401, recorder: recorder)

        await Self.expectServerError { _ = try await orchestrator.enroll() }
        #expect(recorder.registerCalled == false)
        #expect(recorder.finishCalled == false)
    }

    /// A cancelled/failed registration propagates unchanged and `finish` is never called.
    @Test @MainActor func registerErrorPropagatesWithoutFinish() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(
            registerError: OwnerPasskeyRegistrationError.canceled,
            recorder: recorder
        )

        do {
            _ = try await orchestrator.enroll()
            Issue.record("expected the registration error to propagate")
        } catch let error as OwnerPasskeyRegistrationError {
            #expect(error == .canceled)
        } catch {
            Issue.record("expected OwnerPasskeyRegistrationError, got \(error)")
        }
        #expect(recorder.finishCalled == false)
    }

    /// A `finish` reject (after a good registration) surfaces as the generic
    /// `BootstrapError` — no branch on the code.
    @Test @MainActor func finishRejectPropagatesGenericError() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(finishStatus: 401, recorder: recorder)

        await Self.expectServerError { _ = try await orchestrator.enroll() }
        #expect(recorder.registerCalled == true)
        #expect(recorder.finishCalled == true)  // the request was sent; the server rejected
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

    private static func hexDecode(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
#endif
