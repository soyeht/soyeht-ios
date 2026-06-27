import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerPasskeyRegistrationStatusClientTests {
    struct Vectors: Decodable {
        let statusRequests: [RequestVector]
        let statusResponses: [StatusResponseVector]
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

    struct StatusResponseVector: Decodable {
        let id: String
        let input: StatusInput
        let canonicalCborHex: String
    }

    struct StatusInput: Decodable {
        let v: UInt8
        let enrolled: Bool
    }

    struct RejectVector: Decodable {
        let id: String
        let status: Int
        let contentType: String
        let canonicalCborHex: String
    }

    enum FixtureError: Error { case missingFixture }

    @Test func fetchPostsCanonicalStatusBodyAndDecodesNeverEnrolled() async throws {
        let vectors = try Self.loadVectors()
        let requestVector = try #require(vectors.statusRequests.first)
        let responseVector = try #require(vectors.statusResponses.first { $0.id == "status-response-never-enrolled" })
        let responseBody = try #require(Data(soyehtHex: responseVector.canonicalCborHex))
        let mock = HTTPMock(responses: [.init(status: 200, body: responseBody)])
        let identity = RecordingIdentity()
        let signer = HouseholdPoPSigner(ownerIdentity: identity, now: { Date(timeIntervalSince1970: 1_800_000_300) })
        let client = OwnerPasskeyRegistrationStatusClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in try mock.perform(req) }
        )

        let response = try await client.fetch()

        let request = try #require(mock.requests.first)
        let body = try #require(request.httpBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == OwnerPasskeyRegistrationStatusClient.path)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Accept") == BootstrapWire.contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(body.soyehtHexEncodedString() == requestVector.canonicalCborHex)
        #expect(OwnerPasskeyRegistrationStatusRequest().canonicalBytes().soyehtHexEncodedString() == requestVector.canonicalCborHex)
        #expect(response.version == responseVector.input.v)
        #expect(response.enrolled == false)

        let signingContext = try #require(identity.signingContexts.first)
        let signed = try Self.map(HouseholdCBOR.decode(signingContext), "signingContext")
        #expect(signed["method"] == .text("POST"))
        #expect(signed["path_and_query"] == .text(OwnerPasskeyRegistrationStatusClient.path))
        #expect(signed["body_hash"] == .bytes(HouseholdHash.blake3(body)))
    }

    @Test func fetchDecodesEnrolledTrueVector() async throws {
        let vectors = try Self.loadVectors()
        let responseVector = try #require(vectors.statusResponses.first { $0.id == "status-response-enrolled" })
        let responseBody = try #require(Data(soyehtHex: responseVector.canonicalCborHex))
        let mock = HTTPMock(responses: [.init(status: 200, body: responseBody)])
        let client = Self.makeClient(mock: mock)

        let response = try await client.fetch()

        #expect(response.version == responseVector.input.v)
        #expect(response.enrolled == true)
    }

    @Test func fetchRejectsOpaque401AsGenericBootstrapError() async throws {
        let vectors = try Self.loadVectors()
        let reject = try #require(vectors.registrationRejects.first)
        let rejectBody = try #require(Data(soyehtHex: reject.canonicalCborHex))
        let mock = HTTPMock(responses: [.init(status: reject.status, body: rejectBody)])
        let client = Self.makeClient(mock: mock)

        await #expect(throws: BootstrapError.serverError(code: "unauthenticated", message: nil)) {
            _ = try await client.fetch()
        }
    }

    @Test func popAuthorizationIsFreshPerRequest() async throws {
        let vectors = try Self.loadVectors()
        let responseVector = try #require(vectors.statusResponses.first { $0.id == "status-response-enrolled" })
        let responseBody = try #require(Data(soyehtHex: responseVector.canonicalCborHex))
        let mock = HTTPMock(responses: [
            .init(status: 200, body: responseBody),
            .init(status: 200, body: responseBody),
        ])
        let clock = IncrementingClock(start: 1_800_000_400)
        let client = Self.makeClient(mock: mock, now: { clock.next() })

        _ = try await client.fetch()
        _ = try await client.fetch()

        #expect(mock.requests.count == 2)
        let first = mock.requests[0].value(forHTTPHeaderField: "Authorization")
        let second = mock.requests[1].value(forHTTPHeaderField: "Authorization")
        #expect(first?.contains(":1800000400:") == true)
        #expect(second?.contains(":1800000401:") == true)
        #expect(first != second)
    }

    @Test func statusResponseVectorsAreCanonicalCBOR() throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.statusResponses.count == 2)

        for vector in vectors.statusResponses {
            let data = try #require(Data(soyehtHex: vector.canonicalCborHex))
            let value = try HouseholdCBOR.decode(data)
            #expect(HouseholdCBOR.encode(value) == data)
            let response = try OwnerPasskeyRegistrationStatusResponse(cbor: value)
            #expect(response.version == vector.input.v)
            #expect(response.enrolled == vector.input.enrolled)
        }
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
    ) -> OwnerPasskeyRegistrationStatusClient {
        OwnerPasskeyRegistrationStatusClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: HouseholdPoPSigner(ownerIdentity: RecordingIdentity(), now: now),
            transport: { req in try mock.perform(req) }
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
