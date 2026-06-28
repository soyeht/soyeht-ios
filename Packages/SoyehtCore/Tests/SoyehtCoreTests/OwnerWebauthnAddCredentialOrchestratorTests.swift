#if canImport(AuthenticationServices)
import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerWebauthnAddCredentialOrchestratorTests {
    private static let cborContentType = "application/cbor"

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(SHA256.hash(data: payload)) }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _authRequest: OwnerPasskeyAssertionRequest?
        private var _registerRequest: OwnerPasskeyRegistrationRequest?
        private var _finishBody: Data?
        private var _authCalled = false
        private var _registerCalled = false
        private var _finishCalled = false

        func recordAuth(_ request: OwnerPasskeyAssertionRequest) {
            lock.lock()
            _authRequest = request
            _authCalled = true
            lock.unlock()
        }

        func recordRegister(_ request: OwnerPasskeyRegistrationRequest) {
            lock.lock()
            _registerRequest = request
            _registerCalled = true
            lock.unlock()
        }

        func recordFinish(_ body: Data?) {
            lock.lock()
            _finishBody = body
            _finishCalled = true
            lock.unlock()
        }

        var authRequest: OwnerPasskeyAssertionRequest? {
            lock.lock()
            defer { lock.unlock() }
            return _authRequest
        }

        var registerRequest: OwnerPasskeyRegistrationRequest? {
            lock.lock()
            defer { lock.unlock() }
            return _registerRequest
        }

        var finishBody: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _finishBody
        }

        var authCalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _authCalled
        }

        var registerCalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _registerCalled
        }

        var finishCalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _finishCalled
        }
    }

    private struct Vectors: Decodable {
        let addCredentialStartResponses: [Case]
    }

    private struct Case: Decodable {
        let canonicalCborHex: String
    }

    private struct SampleError: Error {}
    enum FixtureError: Error { case missing }

    @Test @MainActor func prepareOnlyStartsAndExposesAddCredentialContext() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(recorder: recorder)

        let prepared = try await orchestrator.prepare()

        #expect(prepared.startResponse.context.op == .addCredential)
        #expect(recorder.authCalled == false)
        #expect(recorder.registerCalled == false)
        #expect(recorder.finishCalled == false)
    }

    @Test @MainActor func happyPathAuthenticatesThenRegistersThenSubmitsCompositeFinish() async throws {
        let recorder = Recorder()
        let assertion = Self.sampleAssertion()
        let attestation = Self.sampleAttestation()
        let orchestrator = try Self.makeOrchestrator(
            attestation: attestation,
            assertion: assertion,
            recorder: recorder
        )

        let result = try await orchestrator.addCredential()

        let start = try Self.startResponse()
        #expect(recorder.authRequest == OwnerWebauthnAddCredentialClient.assertionRequest(from: start))
        let expectedRegistrationRequest = try OwnerWebauthnAddCredentialClient.registrationRequest(from: start)
        #expect(recorder.registerRequest == expectedRegistrationRequest)

        let expectedFinish = OwnerWebauthnAddCredentialClient.finishRequest(
            from: start,
            attestation: attestation,
            assertion: assertion
        )
        #expect(recorder.finishBody == expectedFinish.canonicalBytes())
        #expect(result.credentialID == Data([0x44, 0x55, 0x66]))
        #expect(result.activeCredentialCount == 2)
    }

    @Test @MainActor func startRejectPropagatesWithoutCeremoniesOrFinish() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(startStatus: 401, recorder: recorder)

        await Self.expectUnauthenticated { _ = try await orchestrator.addCredential() }
        #expect(recorder.authCalled == false)
        #expect(recorder.registerCalled == false)
        #expect(recorder.finishCalled == false)
    }

    @Test @MainActor func authenticateErrorPropagatesWithoutRegistrationOrFinish() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(authError: SampleError(), recorder: recorder)

        do {
            _ = try await orchestrator.addCredential()
            Issue.record("expected authenticate error to propagate")
        } catch is SampleError {
            // expected
        } catch {
            Issue.record("expected SampleError, got \(error)")
        }
        #expect(recorder.authCalled == true)
        #expect(recorder.registerCalled == false)
        #expect(recorder.finishCalled == false)
    }

    @Test @MainActor func registrationErrorPropagatesWithoutFinish() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(registerError: SampleError(), recorder: recorder)

        do {
            _ = try await orchestrator.addCredential()
            Issue.record("expected register error to propagate")
        } catch is SampleError {
            // expected
        } catch {
            Issue.record("expected SampleError, got \(error)")
        }
        #expect(recorder.authCalled == true)
        #expect(recorder.registerCalled == true)
        #expect(recorder.finishCalled == false)
    }

    @Test @MainActor func finishRejectPropagatesGenericError() async throws {
        let recorder = Recorder()
        let orchestrator = try Self.makeOrchestrator(finishStatus: 401, recorder: recorder)

        await Self.expectUnauthenticated { _ = try await orchestrator.addCredential() }
        #expect(recorder.authCalled == true)
        #expect(recorder.registerCalled == true)
        #expect(recorder.finishCalled == true)
    }

    @MainActor
    private static func makeOrchestrator(
        startStatus: Int = 200,
        finishStatus: Int = 200,
        attestation: OwnerPasskeyAttestation? = nil,
        assertion: OwnerPasskeyAssertion? = nil,
        authError: Error? = nil,
        registerError: Error? = nil,
        recorder: Recorder
    ) throws -> OwnerWebauthnAddCredentialOrchestrator {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = OwnerWebauthnAddCredentialClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                let path = req.url?.path ?? ""
                let isStart = path.hasSuffix("/add-credential/start")
                let status = isStart ? startStatus : finishStatus
                let body: Data
                if isStart {
                    body = status == 200 ? try Self.startResponseBody() : Self.errorEnvelope()
                } else {
                    recorder.recordFinish(req.httpBody)
                    body = status == 200
                        ? Self.finishResponseBody(credentialID: Data([0x44, 0x55, 0x66]), activeCount: 2)
                        : Self.errorEnvelope()
                }
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": cborContentType]
                )!
                return (body, resp)
            }
        )
        return OwnerWebauthnAddCredentialOrchestrator(
            client: client,
            authenticate: { request in
                recorder.recordAuth(request)
                if let authError { throw authError }
                return assertion ?? Self.sampleAssertion()
            },
            register: { request in
                recorder.recordRegister(request)
                if let registerError { throw registerError }
                return attestation ?? Self.sampleAttestation()
            }
        )
    }

    private static func expectUnauthenticated(_ op: () async throws -> Void) async {
        do {
            try await op()
            Issue.record("expected a throw on opaque 401")
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

    private static func startResponse() throws -> OwnerWebauthnAddCredentialStartResponse {
        try OwnerWebauthnAddCredentialStartResponse(
            cbor: BootstrapWire.decodeCanonical(try startResponseBody())
        )
    }

    private static func startResponseBody() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "owner_webauthn_add_credential_wire_vectors",
            withExtension: "json"
        ) else {
            throw FixtureError.missing
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: try Data(contentsOf: url))
        let vector = try #require(vectors.addCredentialStartResponses.first)
        return try #require(Data(soyehtHex: vector.canonicalCborHex))
    }

    private static func finishResponseBody(credentialID: Data, activeCount: UInt64) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "credential_id": .bytes(credentialID),
            "active_credential_count": .unsigned(activeCount),
        ]))
    }

    private static func errorEnvelope() -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))
    }

    private static func sampleAttestation() -> OwnerPasskeyAttestation {
        OwnerPasskeyAttestation(
            credentialID: Data([0x11, 0x22, 0x33]),
            attestationObject: Data([0xA0, 0xA1]),
            clientDataJSON: Data([0xB0])
        )
    }

    private static func sampleAssertion() -> OwnerPasskeyAssertion {
        OwnerPasskeyAssertion(
            credentialID: Data([0xAA, 0xAA]),
            authenticatorData: Data([0xBB, 0xBB, 0xBB]),
            clientDataJSON: Data([0xCC]),
            signature: Data([0xDD, 0xDD]),
            userHandle: Data([0xEE])
        )
    }
}
#endif
