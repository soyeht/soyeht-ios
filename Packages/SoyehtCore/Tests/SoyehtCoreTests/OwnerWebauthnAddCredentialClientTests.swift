import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerWebauthnAddCredentialClientTests {
    private static let cborContentType = "application/cbor"

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(SHA256.hash(data: payload)) }
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func add(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var last: URLRequest? { all.last }
    }

    private final class HTTPMock: @unchecked Sendable {
        struct Response {
            let status: Int
            let body: Data
        }

        private let lock = NSLock()
        private var responseQueue: [Response]
        private let log: RequestLog

        init(responses: [Response], log: RequestLog = RequestLog()) {
            self.responseQueue = responses
            self.log = log
        }

        var requests: [URLRequest] { log.all }

        func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
            let response: Response
            lock.lock()
            log.add(request)
            if responseQueue.isEmpty {
                lock.unlock()
                throw BootstrapError.networkDrop
            }
            response = responseQueue.removeFirst()
            lock.unlock()

            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": cborContentType]
            )!
            return (response.body, http)
        }
    }

    private struct Vectors: Decodable {
        let addCredentialStartResponses: [Case]
    }

    private struct Case: Decodable {
        let canonicalCborHex: String
    }

    enum FixtureError: Error { case missing }

    @Test func startPostsCanonicalBodyAndDecodesCompositeResponse() async throws {
        let startBody = try Self.startResponseBody()
        let mock = HTTPMock(responses: [.init(status: 200, body: startBody)])
        let client = Self.makeClient(mock: mock)

        let response = try await client.start()

        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == OwnerWebauthnAddCredentialClient.startPath)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Accept") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(request.httpBody == OwnerWebauthnAddCredentialStartRequest().canonicalBytes())
        #expect(request.httpBody?.soyehtHexEncodedString() == "a1617601")

        #expect(response.context.op == .addCredential)
        #expect(response.context.canonicalBytes() == response.approval.context.canonicalBytes())

        let registration = try OwnerWebauthnAddCredentialClient.registrationRequest(from: response)
        #expect(registration.relyingPartyIdentifier == response.registration.options.publicKey.rp.id)
        #expect(registration.challenge == response.registration.options.publicKey.challengeData)

        let assertion = OwnerWebauthnAddCredentialClient.assertionRequest(from: response)
        #expect(assertion.relyingPartyIdentifier == response.approval.relyingPartyIdentifier)
        #expect(assertion.challenge == response.approval.challenge)
        #expect(assertion.allowedCredentialIDs == response.approval.allowedCredentialIDs)
        #expect(assertion.userVerification == response.approval.userVerification)
    }

    @Test func finishPostsCompositeCanonicalBodyAndDecodesResult() async throws {
        let start = try Self.startResponse()
        let finish = OwnerWebauthnAddCredentialClient.finishRequest(
            from: start,
            attestation: Self.sampleAttestation(),
            assertion: Self.sampleAssertion()
        )
        let resultCredentialID = Data([0x44, 0x55, 0x66])
        let mock = HTTPMock(responses: [
            .init(status: 200, body: Self.finishResponseBody(credentialID: resultCredentialID, activeCount: 2)),
        ])
        let client = Self.makeClient(mock: mock)

        let result = try await client.finish(request: finish)

        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == OwnerWebauthnAddCredentialClient.finishPath)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Accept") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(request.httpBody == finish.canonicalBytes())
        #expect(result.credentialID == resultCredentialID)
        #expect(result.activeCredentialCount == 2)
    }

    @Test func startAndFinishRejectOpaque401AsGenericBootstrapError() async throws {
        let reject = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))

        let startMock = HTTPMock(responses: [.init(status: 401, body: reject)])
        let startClient = Self.makeClient(mock: startMock)
        await Self.expectUnauthenticated { _ = try await startClient.start() }

        let finishMock = HTTPMock(responses: [.init(status: 401, body: reject)])
        let finishClient = Self.makeClient(mock: finishMock)
        let finish = OwnerWebauthnAddCredentialClient.finishRequest(
            from: try Self.startResponse(),
            attestation: Self.sampleAttestation(),
            assertion: Self.sampleAssertion()
        )
        await Self.expectUnauthenticated { _ = try await finishClient.finish(request: finish) }
    }

    @Test func popBindsFinishPathAndBody() async throws {
        let log = RequestLog()
        let mock = HTTPMock(responses: [
            .init(status: 200, body: Self.finishResponseBody(credentialID: Data([0x01]), activeCount: 2)),
        ], log: log)
        let client = Self.makeClient(mock: mock)
        let finish = OwnerWebauthnAddCredentialClient.finishRequest(
            from: try Self.startResponse(),
            attestation: Self.sampleAttestation(),
            assertion: Self.sampleAssertion()
        )

        _ = try await client.finish(request: finish)

        let request = try #require(log.last)
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("Soyeht-PoP v1:p_owner:"))
        #expect(request.url?.path == OwnerWebauthnAddCredentialClient.finishPath)
        #expect(request.httpBody == finish.canonicalBytes())
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

    private static func makeClient(mock: HTTPMock) -> OwnerWebauthnAddCredentialClient {
        OwnerWebauthnAddCredentialClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: HouseholdPoPSigner(
                ownerIdentity: MockOwnerIdentity(),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            transport: { req in try mock.perform(req) }
        )
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
