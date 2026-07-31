import Foundation
import Testing

@testable import SoyehtCore

struct RosterAdmitClientTests {
    private final class SigningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var payload: Data? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ d: Data) { lock.lock(); stored = d; lock.unlock() }
    }

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        let box: SigningBox
        func sign(_ payload: Data) throws -> Data {
            box.set(payload)
            return Data(repeating: 0x11, count: 64)
        }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ r: URLRequest) { lock.lock(); stored = r; lock.unlock() }
    }

    private func makeClient(
        status: Int,
        responseBody: Data,
        contentType: String? = "application/cbor",
        box: RequestBox? = nil,
        signingBox: SigningBox = SigningBox()
    ) -> RosterAdmitClient {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(box: signingBox),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return RosterAdmitClient(
            baseURL: URL(string: "http://192.0.2.10:8101")!,
            popSigner: signer,
            perform: { req in
                box?.set(req)
                var headers: [String: String] = [:]
                if let contentType { headers["Content-Type"] = contentType }
                let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (responseBody, resp)
            }
        )
    }

    private func successBody(_ outcome: String) -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text(outcome)]))
    }

    private func errorBody(_ literal: String) -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text(literal)]))
    }

    @Test func popSignsExactSigningContext() async throws {
        let box = RequestBox()
        let signingBox = SigningBox()
        let checkpoint = Data(repeating: 0xAB, count: 64)
        let client = makeClient(status: 200, responseBody: successBody("accepted"), box: box, signingBox: signingBox)
        _ = try await client.admit(checkpointBytes: checkpoint)
        let req = box.request
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path == "/api/v1/household/roster/admit")
        #expect(req?.httpBody == checkpoint)
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(req?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        let expected = HouseholdCBOR.requestSigningContext(
            method: "POST",
            pathAndQuery: "/api/v1/household/roster/admit",
            timestamp: 1_800_000_000,
            bodyHash: HouseholdHash.blake3(checkpoint)
        )
        #expect(signingBox.payload == expected)
    }

    @Test func admitsAcceptedOutcome() async throws {
        let client = makeClient(status: 200, responseBody: successBody("accepted"))
        let response = try await client.admit(checkpointBytes: Data([1, 2, 3]))
        #expect(response.v == 1)
        #expect(response.outcome == "accepted")
    }

    @Test func acceptsAll14Outcomes() async throws {
        let outcomes = [
            "accepted", "idempotent_duplicate", "rejected_replay", "rejected_gap",
            "rejected_rollback", "rejected_malformed", "rejected_owner", "rejected_caveat",
            "rejected_signature", "rejected_temporal", "rejected_projection",
            "epoch_migration_required", "checkpoint_fork_conflict_recorded", "event_fork_conflict_recorded",
        ]
        for outcome in outcomes {
            let client = makeClient(status: 200, responseBody: successBody(outcome))
            let response = try await client.admit(checkpointBytes: Data([1]))
            #expect(response.outcome == outcome)
        }
    }

    @Test func rejectsUnknownOutcome() async {
        let client = makeClient(status: 200, responseBody: successBody("made_up_outcome"))
        await #expect(throws: RosterAdmitClientError.wire(.malformedResponse)) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsWrongVersion() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(2), "outcome": .text("accepted")]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterAdmitClientError.wire(.malformedResponse)) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsExtraKey() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text("accepted"), "extra": .text("x")]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsMissingOutcome() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsOversizedBodyBeforeTransport() async {
        let box = RequestBox()
        let client = makeClient(status: 200, responseBody: successBody("accepted"), box: box)
        let oversized = Data(repeating: 0xAB, count: RosterWire.admitBodyLimit + 1)
        await #expect(throws: RosterAdmitClientError.wire(.payloadTooLarge)) {
            _ = try await client.admit(checkpointBytes: oversized)
        }
        #expect(box.request == nil)
    }

    @Test func acceptsMaxSizeBody() async throws {
        let client = makeClient(status: 200, responseBody: successBody("accepted"))
        let max = Data(repeating: 0xAB, count: RosterWire.admitBodyLimit)
        let response = try await client.admit(checkpointBytes: max)
        #expect(response.outcome == "accepted")
    }

    @Test func rejectsWrongResponseContentType() async {
        let client = makeClient(status: 200, responseBody: successBody("accepted"), contentType: "application/json")
        await #expect(throws: RosterWireError.unsupportedContentType) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func maps401Unauthenticated() async {
        let client = makeClient(status: 401, responseBody: errorBody("unauthenticated"))
        await #expect(throws: RosterAdmitClientError.wire(.serverError(code: "unauthenticated"))) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejects401WithWrongLiteral() async {
        let client = makeClient(status: 401, responseBody: errorBody("invalid_request"))
        await #expect(throws: RosterAdmitClientError.wire(.malformedResponse)) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func maps413PayloadTooLarge() async {
        let client = makeClient(status: 413, responseBody: errorBody("payload_too_large"))
        await #expect(throws: RosterAdmitClientError.wire(.serverError(code: "payload_too_large"))) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func maps500InternalError() async {
        let client = makeClient(status: 500, responseBody: errorBody("internal_error"))
        await #expect(throws: RosterAdmitClientError.wire(.serverError(code: "internal_error"))) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejects500WithStatusSpecificLiteral() async {
        let client = makeClient(status: 500, responseBody: errorBody("unauthenticated"))
        await #expect(throws: RosterAdmitClientError.wire(.malformedResponse)) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsUnknownStatus() async {
        let client = makeClient(status: 418, responseBody: errorBody("unauthenticated"))
        await #expect(throws: RosterAdmitClientError.wire(.malformedResponse)) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }

    @Test func rejectsErrorWithoutCBORContentType() async {
        let client = makeClient(status: 401, responseBody: errorBody("unauthenticated"), contentType: "text/plain")
        await #expect(throws: RosterWireError.unsupportedContentType) {
            _ = try await client.admit(checkpointBytes: Data([1]))
        }
    }
}
