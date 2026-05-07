import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("JoinRequestStagingClient")
struct JoinRequestStagingClientTests {
    private static let baseURL = URL(string: "https://casa.local/base")!
    private static let expiry: UInt64 = 1_700_000_240

    @Test func submitPostsCanonicalJoinRequestWithPoPAndParsesAcceptedResponse() async throws {
        let envelope = try Self.envelope()
        let acceptedBody = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "owner_event_cursor": .unsigned(41),
            "expiry": .unsigned(Self.expiry),
        ]))
        let store = RequestStore([
            .init(status: 200, body: acceptedBody),
        ])
        let client = JoinRequestStagingClient(
            baseURL: Self.baseURL,
            authorizationProvider: { method, pathAndQuery, body in
                #expect(method == "POST")
                #expect(pathAndQuery == "/base/api/v1/household/join-request")
                #expect(body == HouseholdCBOR.joinRequest(envelope))
                return "Soyeht-PoP test"
            },
            transport: { request in try await store.perform(request) }
        )

        let accepted = try await client.submit(envelope)

        #expect(accepted == JoinRequestAccepted(ownerEventCursor: 41, expiry: Self.expiry))
        let request = try #require(await store.capturedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/base/api/v1/household/join-request")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Soyeht-PoP test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/cbor")
        #expect(request.httpBody == HouseholdCBOR.joinRequest(envelope))
    }

    @Test func approvePostsAuthorizationBodyToCursorScopedEndpoint() async throws {
        let cursor: UInt64 = 77
        let approvalSignature = Data(repeating: 0xAA, count: 64)
        let authorization = OperatorAuthorizationResult(
            approvalSignature: approvalSignature,
            outerBody: HouseholdCBOR.ownerApprovalBody(
                cursor: cursor,
                approvalSignature: approvalSignature
            ),
            signedContext: Data(repeating: 0xBB, count: 16),
            cursor: cursor,
            timestamp: 1_700_000_000
        )
        let certHash = Data(repeating: 0xCC, count: 32)
        let store = RequestStore([
            .init(
                status: 200,
                body: HouseholdCBOR.encode(.map([
                    "v": .unsigned(1),
                    "machine_cert_hash": .bytes(certHash),
                ]))
            ),
        ])
        let client = OwnerApprovalClient(
            baseURL: Self.baseURL,
            authorizationProvider: { method, pathAndQuery, body in
                #expect(method == "POST")
                #expect(pathAndQuery == "/base/api/v1/household/owner-events/77/approve")
                #expect(body == authorization.outerBody)
                return "Soyeht-PoP approve"
            },
            transport: { request in try await store.perform(request) }
        )

        let ack = try await client.approve(authorization)

        #expect(ack == OwnerApprovalAck(machineCertHash: certHash))
        let request = try #require(await store.capturedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/base/api/v1/household/owner-events/77/approve")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Soyeht-PoP approve")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/cbor")
        #expect(request.httpBody == authorization.outerBody)
    }

    private static func envelope() throws -> JoinRequestEnvelope {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let machinePublicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let hostname = "studio.local"
        let platform = PairMachinePlatform.macos.rawValue
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation
        return JoinRequestEnvelope(
            householdId: "hh_test",
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            rawHostname: hostname,
            rawPlatform: platform,
            candidateAddress: "100.64.1.5:8443",
            ttlUnix: Self.expiry,
            challengeSignature: signature,
            transportOrigin: .qrTailscale,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    struct ResponseSpec: Sendable {
        let status: Int
        let body: Data
        let contentType: String?

        init(status: Int, body: Data, contentType: String? = "application/cbor") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }
    }

    actor RequestStore {
        private var responses: [ResponseSpec]
        private(set) var capturedRequests: [URLRequest] = []

        init(_ responses: [ResponseSpec]) {
            self.responses = responses
        }

        func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
            capturedRequests.append(request)
            guard !responses.isEmpty else { throw TransportDrop() }
            let next = responses.removeFirst()
            var headers: [String: String] = [:]
            if let contentType = next.contentType {
                headers["Content-Type"] = contentType
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: next.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (next.body, response)
        }
    }

    private struct TransportDrop: Error {}
}
