import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerPasskeyEnrollmentClientTests {
    struct Vectors: Decodable {
        let startRequests: [RequestVector]
        let startResponses: [StartVector]
        let finishRequests: [FinishVector]
        let finishResponses: [FinishResponseVector]
        let registrationRejects: [RejectVector]
    }

    struct RequestVector: Decodable {
        let id: String
        let input: VersionInput
        let canonicalCborHex: String
    }

    struct VersionInput: Decodable {
        let v: UInt8
    }

    struct StartVector: Decodable {
        let id: String
        let input: StartInput
        let canonicalCborHex: String
    }

    struct StartInput: Decodable {
        let v: UInt8
        let challengeId: String
        let options: CreationChallengeResponseInput
    }

    struct CreationChallengeResponseInput: Decodable {
        let publicKey: PublicKeyCredentialCreationOptionsInput
    }

    struct PublicKeyCredentialCreationOptionsInput: Decodable {
        let rp: RelyingPartyInput
        let user: UserInput
        let challenge: String
    }

    struct RelyingPartyInput: Decodable {
        let id: String
        let name: String
    }

    struct UserInput: Decodable {
        let id: String
        let name: String
        let displayName: String
    }

    struct FinishVector: Decodable {
        let id: String
        let input: FinishInput
        let canonicalCborHex: String
    }

    struct FinishInput: Decodable {
        let v: UInt8
        let challengeId: String
        let credential: RegisterPublicKeyCredentialInput
    }

    struct RegisterPublicKeyCredentialInput: Decodable {
        let id: String
        let rawId: String
        let response: AuthenticatorAttestationResponseInput
        let type: String
    }

    struct AuthenticatorAttestationResponseInput: Decodable {
        let attestationObject: String
        let clientDataJSON: String
        let transports: [String]?
    }

    struct FinishResponseVector: Decodable {
        let id: String
        let credentialIdHex: String
        let activeCredentialCount: UInt64
        let canonicalCborHex: String
    }

    struct RejectVector: Decodable {
        let id: String
        let status: Int
        let contentType: String
        let canonicalCborHex: String
    }

    enum FixtureError: Error { case missingFixture }

    @Test func startPostsCanonicalBodyAndDecodesOptions() async throws {
        let vectors = try Self.loadVectors()
        let startRequest = try #require(vectors.startRequests.first)
        let startResponse = try #require(vectors.startResponses.first)
        let responseBody = try #require(Data(soyehtHex: startResponse.canonicalCborHex))
        let mock = HTTPMock(responses: [.init(status: 200, body: responseBody)])
        let client = Self.makeClient(mock: mock)

        let response = try await client.start()

        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == OwnerPasskeyEnrollmentClient.startPath)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Accept") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(request.httpBody?.soyehtHexEncodedString() == startRequest.canonicalCborHex)
        #expect(response.version == startResponse.input.v)
        #expect(response.challengeID == startResponse.input.challengeId)

        let registration = try OwnerPasskeyEnrollmentClient.registrationRequest(from: response)
        let expectedPublicKey = startResponse.input.options.publicKey
        #expect(registration.relyingPartyIdentifier == expectedPublicKey.rp.id)
        #expect(registration.challenge == PairingCrypto.base64URLDecode(expectedPublicKey.challenge))
        #expect(registration.userID == PairingCrypto.base64URLDecode(expectedPublicKey.user.id))
        #expect(registration.userName == expectedPublicKey.user.name)
        #expect(registration.userDisplayName == expectedPublicKey.user.displayName)
    }

    @Test func finishPostsCanonicalBodySignsFinishPathAndDecodesCredentialID() async throws {
        let vectors = try Self.loadVectors()
        let finishRequest = try #require(vectors.finishRequests.first)
        let finishResponse = try #require(vectors.finishResponses.first)
        let responseBody = try #require(Data(soyehtHex: finishResponse.canonicalCborHex))
        let mock = HTTPMock(responses: [.init(status: 200, body: responseBody)])
        let identity = RecordingIdentity()
        let signer = HouseholdPoPSigner(ownerIdentity: identity, now: { Date(timeIntervalSince1970: 1_800_000_100) })
        let client = OwnerPasskeyEnrollmentClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in try mock.perform(req) }
        )
        let credential = try Self.credential(from: finishRequest.input.credential)

        let result = try await client.finish(
            challengeID: finishRequest.input.challengeId,
            credential: credential
        )

        let request = try #require(mock.requests.first)
        let body = try #require(request.httpBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == OwnerPasskeyEnrollmentClient.finishPath)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Accept") == BootstrapWire.contentType)
        #expect(body.soyehtHexEncodedString() == finishRequest.canonicalCborHex)
        let expectedCredentialID = try #require(Data(soyehtHex: finishResponse.credentialIdHex))
        #expect(result.credentialID == expectedCredentialID)
        #expect(result.activeCredentialCount == finishResponse.activeCredentialCount)

        let signingContext = try #require(identity.signingContexts.first)
        let signed = try Self.map(HouseholdCBOR.decode(signingContext), "signingContext")
        #expect(signed["method"] == .text("POST"))
        #expect(signed["path_and_query"] == .text(OwnerPasskeyEnrollmentClient.finishPath))
        #expect(signed["body_hash"] == .bytes(HouseholdHash.blake3(body)))
    }

    @Test func startAndFinishRejectOpaque401AsGenericBootstrapError() async throws {
        let vectors = try Self.loadVectors()
        let reject = try #require(vectors.registrationRejects.first)
        let rejectBody = try #require(Data(soyehtHex: reject.canonicalCborHex))

        let startMock = HTTPMock(responses: [.init(status: reject.status, body: rejectBody)])
        let startClient = Self.makeClient(mock: startMock)
        await #expect(throws: BootstrapError.serverError(code: "unauthenticated", message: nil)) {
            _ = try await startClient.start()
        }

        let finishVector = try #require(vectors.finishRequests.first)
        let finishMock = HTTPMock(responses: [.init(status: reject.status, body: rejectBody)])
        let finishClient = Self.makeClient(mock: finishMock)
        let credential = try Self.credential(from: finishVector.input.credential)
        await #expect(throws: BootstrapError.serverError(code: "unauthenticated", message: nil)) {
            _ = try await finishClient.finish(
                challengeID: finishVector.input.challengeId,
                credential: credential
            )
        }
    }

    @Test func popAuthorizationIsFreshPerRequest() async throws {
        let vectors = try Self.loadVectors()
        let startResponse = try #require(vectors.startResponses.first)
        let responseBody = try #require(Data(soyehtHex: startResponse.canonicalCborHex))
        let mock = HTTPMock(responses: [
            .init(status: 200, body: responseBody),
            .init(status: 200, body: responseBody),
        ])
        let clock = IncrementingClock(start: 1_800_000_200)
        let client = Self.makeClient(mock: mock, now: { clock.next() })

        _ = try await client.start()
        _ = try await client.start()

        #expect(mock.requests.count == 2)
        let first = mock.requests[0].value(forHTTPHeaderField: "Authorization")
        let second = mock.requests[1].value(forHTTPHeaderField: "Authorization")
        #expect(first?.contains(":1800000200:") == true)
        #expect(second?.contains(":1800000201:") == true)
        #expect(first != second)
    }

    @Test func localSocketModeOmitsPoPAuthorizationForStartAndFinish() async throws {
        let vectors = try Self.loadVectors()
        let startResponse = try #require(vectors.startResponses.first)
        let finishRequest = try #require(vectors.finishRequests.first)
        let finishResponse = try #require(vectors.finishResponses.first)
        let startBody = try #require(Data(soyehtHex: startResponse.canonicalCborHex))
        let finishBody = try #require(Data(soyehtHex: finishResponse.canonicalCborHex))
        let mock = HTTPMock(responses: [
            .init(status: 200, body: startBody),
            .init(status: 200, body: finishBody),
        ])
        let client = OwnerPasskeyEnrollmentClient(
            localSocketBaseURL: URL(string: "http://soyeht-local")!,
            transport: { req in try mock.perform(req) }
        )
        let credential = try Self.credential(from: finishRequest.input.credential)

        _ = try await client.start()
        _ = try await client.finish(
            challengeID: finishRequest.input.challengeId,
            credential: credential
        )

        #expect(mock.requests.count == 2)
        #expect(mock.requests[0].url?.path == OwnerPasskeyEnrollmentClient.startPath)
        #expect(mock.requests[1].url?.path == OwnerPasskeyEnrollmentClient.finishPath)
        #expect(mock.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(mock.requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func mappingFromPlatformAttestationBuildsCanonicalCredential() throws {
        let attestation = OwnerPasskeyAttestation(
            credentialID: Data([0x00, 0x01, 0x02, 0x80, 0xff, 0x7f]),
            attestationObject: Data([0xa1, 0x01, 0x02]),
            clientDataJSON: Data(#"{"type":"webauthn.create"}"#.utf8)
        )

        let credential = OwnerPasskeyEnrollmentClient.credential(from: attestation)

        #expect(credential.rawIdData == attestation.credentialID)
        #expect(credential.response.attestationObjectData == attestation.attestationObject)
        #expect(credential.response.clientData == attestation.clientDataJSON)
        #expect(credential.response.transports == nil)
    }

    private static func loadVectors() throws -> Vectors {
        guard let url = Bundle.module.url(
            forResource: "owner_webauthn_registration_vectors",
            withExtension: "json"
        ) else {
            throw FixtureError.missingFixture
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: try Data(contentsOf: url))
    }

    private static func makeClient(
        mock: HTTPMock,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> OwnerPasskeyEnrollmentClient {
        OwnerPasskeyEnrollmentClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: HouseholdPoPSigner(ownerIdentity: RecordingIdentity(), now: now),
            transport: { req in try mock.perform(req) }
        )
    }

    private static func credential(
        from input: RegisterPublicKeyCredentialInput
    ) throws -> OwnerWebauthnRegisterCredential {
        OwnerWebauthnRegisterCredential(
            id: input.id,
            rawId: input.rawId,
            response: OwnerWebauthnAuthenticatorAttestationResponse(
                attestationObject: input.response.attestationObject,
                clientDataJSON: input.response.clientDataJSON,
                transports: input.response.transports
            ),
            type: input.type
        )
    }

    private static func map(_ value: HouseholdCBORValue, _ label: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else {
            throw AssertionError("\(label) is not a map")
        }
        return map
    }
}

private final class HTTPMock: @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private var responseQueue: [Response]
    private var storedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responseQueue = responses
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
        let response: Response
        lock.lock()
        storedRequests.append(request)
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
            headerFields: ["Content-Type": BootstrapWire.contentType]
        )!
        return (response.body, http)
    }
}

private final class RecordingIdentity: OwnerIdentitySigning, @unchecked Sendable {
    let personId = "p_owner"
    let publicKey = Data(repeating: 0x02, count: 33)
    let keyReference = "test-owner-key"

    private let lock = NSLock()
    private var storedSigningContexts: [Data] = []

    var signingContexts: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedSigningContexts
    }

    func sign(_ payload: Data) throws -> Data {
        lock.lock()
        storedSigningContexts.append(payload)
        lock.unlock()
        return Data(repeating: 0x11, count: 64)
    }
}

private final class IncrementingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(start: TimeInterval) {
        self.current = start
    }

    func next() -> Date {
        lock.lock()
        defer {
            current += 1
            lock.unlock()
        }
        return Date(timeIntervalSince1970: current)
    }
}

private struct AssertionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
