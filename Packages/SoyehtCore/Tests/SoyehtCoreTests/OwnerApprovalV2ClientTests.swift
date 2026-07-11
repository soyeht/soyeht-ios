import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// The `OwnerApprovalV2Client` HTTP layer (headless, injected transport — no live
/// engine): `start` POSTs the start request and decodes the start response;
/// `approveV2` encodes the signed envelope and POSTs it to `/approve`. Asserts
/// method/path/headers/canonical-body, fresh+bound PoP, and the opaque-401
/// anti-oracle mapping.
@Suite struct OwnerApprovalV2ClientTests {
    private static let cborContentType = "application/cbor"

    /// Owner-identity stub whose signature is DERIVED from the payload, so a
    /// changed signing context (method/path/timestamp/body-hash) yields a changed
    /// signature — letting the tests prove the PoP is bound + fresh.
    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(SHA256.hash(data: payload)) }
    }

    /// Thread-safe capture of the outbound request(s) from the `@Sendable` transport.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var last: URLRequest? { all.last }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = value; value += 1; return v }
    }

    private static func makeClient(
        status: Int,
        responseBody: Data,
        log: RequestLog? = nil,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> OwnerApprovalV2Client {
        let signer = HouseholdPoPSigner(ownerIdentity: MockOwnerIdentity(), now: now)
        return OwnerApprovalV2Client(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                log?.add(req)
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": cborContentType]
                )!
                return (responseBody, resp)
            }
        )
    }

    enum FixtureError: Error { case missing }

    /// A real server start-response (canonical CBOR) from the wire vectors, used
    /// as the canned `start` response body so the decoder is exercised end to end.
    private static func startResponseBody() throws -> Data {
        struct Vectors: Decodable { let ownerApprovalStartResponses: [Case] }
        struct Case: Decodable { let canonicalCborHex: String }
        guard let url = Bundle.module.url(forResource: "owner_approval_v2_wire_vectors", withExtension: "json") else {
            throw FixtureError.missing
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: try Data(contentsOf: url))
        return hexDecode(vectors.ownerApprovalStartResponses[0].canonicalCborHex)
    }

    private static func sampleFinish() -> OwnerApprovalV2Finish {
        let context = OwnerApprovalContextV2(
            op: .pairMachineApprove,
            householdID: "hh_test",
            ownerPersonID: "p_owner",
            capabilities: ["machine-cert"],
            issuedAt: 1,
            expiresAt: 2,
            replayNonce: Data([0x09])
        )
        return OwnerApprovalV2Finish(
            challengeID: "0123456789abcdef0123456789abcdef",
            approval: OwnerApprovalV2(
                context: context,
                credentialID: Data([0x01]),
                authenticatorData: Data([0x02]),
                clientDataJSON: Data([0x03]),
                signature: Data([0x04])
            )
        )
    }

    private static func invalidMobileFinish() -> OwnerApprovalV2Finish {
        let context = OwnerApprovalContextV2(
            op: .mobileClawVPNDevE2EExecute,
            householdID: "hh_" + String(repeating: "a", count: 52),
            ownerPersonID: "p_owner",
            mobileClawVPNExecutionHash: nil,
            capabilities: [MobileClawVPNDevE2EExecutionTupleV1.capability],
            issuedAt: 1,
            expiresAt: 2,
            replayNonce: Data(repeating: 0x09, count: 32)
        )
        return OwnerApprovalV2Finish(
            challengeID: "0123456789abcdef0123456789abcdef",
            approval: OwnerApprovalV2(
                context: context,
                credentialID: Data([0x01]),
                authenticatorData: Data([0x02]),
                clientDataJSON: Data([0x03]),
                signature: Data([0x04])
            )
        )
    }

    // MARK: start

    @Test func startBuildsCanonicalRequestAndDecodesResponse() async throws {
        let log = RequestLog()
        let client = Self.makeClient(status: 200, responseBody: try Self.startResponseBody(), log: log)

        let response = try await client.start(cursor: 7)

        let req = try #require(log.last)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/v1/household/owner-events/7/approval-v2/start")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == Self.cborContentType)
        #expect(req.value(forHTTPHeaderField: "Accept") == Self.cborContentType)
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(req.httpBody == OwnerApprovalV2StartRequest().canonicalBytes())
        #expect(req.httpBody?.soyehtHexEncodedString() == "a1617601")  // canonical { v: 1 }
        // decoded a real server start-response
        #expect(!response.challengeID.isEmpty)
        #expect(response.relyingPartyIdentifier == "alpha.example.test")
        #expect(response.challenge == PairingCrypto.base64URLDecode("AQIDBAUGBwg"))
    }

    // MARK: approveV2

    @Test func approveV2BuildsCanonicalEnvelopeRequestAndSucceedsOn2xx() async throws {
        let log = RequestLog()
        let client = Self.makeClient(
            status: 200,
            responseBody: HouseholdCBOR.encode(.map(["v": .unsigned(1)])),
            log: log
        )
        let finish = Self.sampleFinish()

        try await client.approveV2(cursor: 7, finish: finish)

        let req = try #require(log.last)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/v1/household/owner-events/7/approve")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == Self.cborContentType)
        #expect(req.value(forHTTPHeaderField: "Accept") == Self.cborContentType)
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        #expect(req.httpBody == (try finish.canonicalBytes()))
    }

    @Test func approveV2RejectsInvalidMobileShapeBeforeTransport() async {
        let log = RequestLog()
        let client = Self.makeClient(
            status: 200,
            responseBody: HouseholdCBOR.encode(.map(["v": .unsigned(1)])),
            log: log
        )

        do {
            try await client.approveV2(cursor: 7, finish: Self.invalidMobileFinish())
            Issue.record("expected invalid mobile owner approval shape to fail")
        } catch is OwnerApprovalV2DTOError {
            #expect(log.all.isEmpty)
        } catch {
            Issue.record("expected OwnerApprovalV2DTOError, got \(error)")
        }
    }

    // MARK: opaque-401 anti-oracle

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

    @Test func startMapsOpaque401ToGenericServerError() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))
        let client = Self.makeClient(status: 401, responseBody: body)
        await Self.expectUnauthenticated { _ = try await client.start(cursor: 7) }
    }

    @Test func approveV2MapsOpaque401ToGenericServerError() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unauthenticated")]))
        let client = Self.makeClient(status: 401, responseBody: body)
        await Self.expectUnauthenticated { try await client.approveV2(cursor: 7, finish: Self.sampleFinish()) }
    }

    // MARK: PoP fresh + bound

    /// Same clock; `start` (path A, body `{v:1}`) vs `approveV2` (path B, envelope
    /// body) → different Authorization headers ⇒ the PoP signature binds path+body.
    @Test func popBindsPathAndBody() async throws {
        let startLog = RequestLog()
        let startClient = Self.makeClient(status: 200, responseBody: try Self.startResponseBody(), log: startLog)
        _ = try await startClient.start(cursor: 7)
        let startAuth = try #require(startLog.last?.value(forHTTPHeaderField: "Authorization"))

        let approveLog = RequestLog()
        let approveClient = Self.makeClient(
            status: 200,
            responseBody: HouseholdCBOR.encode(.map(["v": .unsigned(1)])),
            log: approveLog
        )
        try await approveClient.approveV2(cursor: 7, finish: Self.sampleFinish())
        let approveAuth = try #require(approveLog.last?.value(forHTTPHeaderField: "Authorization"))

        #expect(startAuth.hasPrefix("Soyeht-PoP v1:p_owner:"))
        #expect(approveAuth.hasPrefix("Soyeht-PoP v1:p_owner:"))
        #expect(startAuth != approveAuth, "PoP must bind path+body (distinct request → distinct signature)")
    }

    /// Incrementing clock; two `start` calls → distinct timestamps → distinct
    /// headers ⇒ the PoP is recomputed fresh per request, not cached.
    @Test func popIsFreshPerRequest() async throws {
        let counter = Counter()
        let log = RequestLog()
        let client = Self.makeClient(
            status: 200,
            responseBody: try Self.startResponseBody(),
            log: log,
            now: { Date(timeIntervalSince1970: 1_800_000_000 + Double(counter.next())) }
        )

        _ = try await client.start(cursor: 7)
        _ = try await client.start(cursor: 7)

        let auths = log.all.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auths.count == 2)
        #expect(auths[0] != auths[1], "PoP must be recomputed fresh per request (distinct timestamps)")
    }

    // MARK: helpers

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
