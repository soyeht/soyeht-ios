import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("OwnerEventsLongPoll")
struct OwnerEventsLongPollTests {
    private static let baseURL = URL(string: "https://household.example")!
    private static let householdId = "hh_test"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let expiry = UInt64(1_700_000_240)

    @Test func pollOnceBuildsLongPollRequestWithPoPAndCBORCursor() async throws {
        let store = RequestStore([
            .init(status: 204, body: Data(), contentType: nil),
        ])
        let poller = try Self.poller(
            queue: JoinRequestQueue(),
            store: store,
            authorization: "Soyeht-PoP test"
        )

        let result = try await poller.pollOnce(now: Self.now)

        #expect(result.timedOut)
        #expect(result.previousCursor == 0)
        #expect(result.cursor == 0)
        let captured = try #require(await store.capturedRequests.first)
        #expect(captured.httpMethod == "GET")
        #expect(captured.url?.path == "/api/v1/household/owner-events")
        #expect(captured.url?.query == "since=AA")
        #expect(captured.value(forHTTPHeaderField: "Accept") == "application/cbor")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Soyeht-PoP test")
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(captured.httpBody == nil)
        #expect(captured.timeoutInterval == 45)
    }

    @Test func joinRequestEnqueuesAndAdvancesCursorAfterVerification() async throws {
        let fixture = try Self.joinRequestFixture()
        let event = try Self.joinRequestEvent(
            cursor: 41,
            joinRequestCBOR: fixture.cbor,
            fingerprint: fixture.fingerprint
        )
        let store = RequestStore([
            .init(status: 200, body: Self.response(events: [event], nextCursor: 42)),
        ])
        let queue = JoinRequestQueue()
        let verifier = EventVerifierRecorder()
        let poller = try Self.poller(
            queue: queue,
            store: store,
            verifier: { event in await verifier.record(event) }
        )

        let result = try await poller.pollOnce(now: Self.now)

        #expect(result.timedOut == false)
        #expect(result.previousCursor == 0)
        #expect(result.cursor == 42)
        #expect(await poller.currentCursor() == 42)
        #expect(result.enqueuedJoinRequests.count == 1)
        #expect(result.duplicateJoinRequests.isEmpty)
        let envelope = try #require(result.enqueuedJoinRequests.first)
        #expect(envelope.householdId == Self.householdId)
        #expect(envelope.machinePublicKey == fixture.machinePublicKey)
        #expect(envelope.nonce == fixture.nonce)
        #expect(envelope.rawHostname == "studio.local")
        #expect(envelope.rawPlatform == PairMachinePlatform.macos.rawValue)
        #expect(envelope.candidateAddress == "100.64.1.5:8443")
        #expect(envelope.ttlUnix == Self.expiry)
        #expect(envelope.transportOrigin == JoinRequestTransportOrigin.bonjourShortcut)
        #expect(await queue.contains(idempotencyKey: envelope.idempotencyKey))
        #expect(await queue.cursor(forIdempotencyKey: envelope.idempotencyKey) == 41)
        #expect(await queue.pendingEntries(now: Self.now).count == 1)
        #expect(await queue.pendingRequests(now: Self.now).map(\.cursor) == [41])
        #expect(await verifier.events.count == 1)
    }

    @Test func duplicateJoinRequestDoesNotDoubleEnqueueButStillAdvancesCursor() async throws {
        let fixture = try Self.joinRequestFixture()
        let first = try Self.joinRequestEvent(
            cursor: 1,
            joinRequestCBOR: fixture.cbor,
            fingerprint: fixture.fingerprint
        )
        let duplicate = try Self.joinRequestEvent(
            cursor: 2,
            joinRequestCBOR: fixture.cbor,
            fingerprint: fixture.fingerprint
        )
        let store = RequestStore([
            .init(status: 200, body: Self.response(events: [first], nextCursor: 1)),
            .init(status: 200, body: Self.response(events: [duplicate], nextCursor: 2)),
        ])
        let queue = JoinRequestQueue()
        let poller = try Self.poller(queue: queue, store: store)

        let firstResult = try await poller.pollOnce(now: Self.now)
        let secondResult = try await poller.pollOnce(now: Self.now)

        #expect(firstResult.enqueuedJoinRequests.count == 1)
        #expect(firstResult.duplicateJoinRequests.isEmpty)
        #expect(secondResult.enqueuedJoinRequests.isEmpty)
        #expect(secondResult.duplicateJoinRequests.count == 1)
        #expect(secondResult.cursor == 2)
        #expect(await poller.currentCursor() == 2)
        #expect(await queue.pendingEntries(now: Self.now).count == 1)
        let secondRequest = try #require(await store.capturedRequests.dropFirst().first)
        #expect(secondRequest.url?.query == "since=AQ")
    }

    @Test func fingerprintMismatchDoesNotAdvanceCursorOrEnqueue() async throws {
        let fixture = try Self.joinRequestFixture()
        let event = try Self.joinRequestEvent(
            cursor: 1,
            joinRequestCBOR: fixture.cbor,
            fingerprint: "wrong words do not match"
        )
        let store = RequestStore([
            .init(status: 200, body: Self.response(events: [event], nextCursor: 2)),
        ])
        let queue = JoinRequestQueue()
        let poller = try Self.poller(queue: queue, store: store)

        do {
            _ = try await poller.pollOnce(now: Self.now)
            Issue.record("Expected derivationDrift")
        } catch let error as MachineJoinError {
            #expect(error == .derivationDrift)
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await poller.currentCursor() == 0)
        #expect(await queue.pendingEntries(now: Self.now).isEmpty)
    }

    @Test func http204KeepsExistingCursor() async throws {
        let store = RequestStore([
            .init(status: 204, body: Data(), contentType: nil),
        ])
        let poller = try Self.poller(
            queue: JoinRequestQueue(),
            store: store,
            initialCursor: 7
        )

        let result = try await poller.pollOnce(now: Self.now)

        #expect(result.timedOut)
        #expect(result.previousCursor == 7)
        #expect(result.cursor == 7)
        #expect(await poller.currentCursor() == 7)
        let captured = try #require(await store.capturedRequests.first)
        #expect(captured.url?.query == "since=Bw")
    }

    @Test func transportFailureMapsToNetworkDrop() async throws {
        let poller = OwnerEventsLongPoll(
            baseURL: Self.baseURL,
            householdId: Self.householdId,
            queue: JoinRequestQueue(),
            wordlist: try BIP39Wordlist(),
            authorizationProvider: { _, _, _ in "Soyeht-PoP test" },
            eventVerifier: { _ in },
            transport: { _ in throw TransportDrop() },
            nowProvider: { Self.now }
        )

        do {
            _ = try await poller.pollOnce(now: Self.now)
            Issue.record("Expected networkDrop")
        } catch let error as MachineJoinError {
            #expect(error == .networkDrop)
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await poller.currentCursor() == 0)
    }

    private static func poller(
        queue: JoinRequestQueue,
        store: RequestStore,
        initialCursor: UInt64 = 0,
        authorization: String = "Soyeht-PoP test",
        verifier: @escaping OwnerEventsLongPoll.EventVerifier = { _ in }
    ) throws -> OwnerEventsLongPoll {
        OwnerEventsLongPoll(
            baseURL: Self.baseURL,
            householdId: Self.householdId,
            queue: queue,
            wordlist: try BIP39Wordlist(),
            initialCursor: initialCursor,
            authorizationProvider: { method, pathAndQuery, body in
                #expect(method == "GET")
                #expect(pathAndQuery.hasPrefix("/api/v1/household/owner-events?since="))
                #expect(body.isEmpty)
                return authorization
            },
            eventVerifier: verifier,
            transport: { request in try await store.perform(request) },
            nowProvider: { Self.now }
        )
    }

    private struct JoinRequestFixture {
        let cbor: Data
        let machinePublicKey: Data
        let nonce: Data
        let fingerprint: String
    }

    private static func joinRequestFixture(
        seed: UInt8 = 0x42,
        nonce: Data = Data(repeating: 0xAB, count: 32),
        hostname: String = "studio.local",
        platform: PairMachinePlatform = .macos,
        transport: PairMachineTransport = .lan,
        address: String = "100.64.1.5:8443"
    ) throws -> JoinRequestFixture {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let machinePublicKey = privateKey.publicKey.compressedRepresentation
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform.rawValue
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation
        let cbor = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "m_pub": .bytes(machinePublicKey),
            "nonce": .bytes(nonce),
            "hostname": .text(hostname),
            "platform": .text(platform.rawValue),
            "addr": .text(address),
            "transport": .text(transport.rawValue),
            "challenge_sig": .bytes(signature),
        ]))
        let fingerprint = try OperatorFingerprint
            .derive(machinePublicKey: machinePublicKey, wordlist: BIP39Wordlist())
            .words
            .joined(separator: " ")
        return JoinRequestFixture(
            cbor: cbor,
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            fingerprint: fingerprint
        )
    }

    private static func joinRequestEvent(
        cursor: UInt64,
        joinRequestCBOR: Data,
        fingerprint: String
    ) throws -> HouseholdCBORValue {
        ownerEvent(
            cursor: cursor,
            type: "join-request",
            payload: [
                "join_request_cbor": .bytes(joinRequestCBOR),
                "fingerprint": .text(fingerprint),
                "expiry": .unsigned(Self.expiry),
            ]
        )
    }

    private static func ownerEvent(
        cursor: UInt64,
        type: String,
        payload: [String: HouseholdCBORValue]
    ) -> HouseholdCBORValue {
        .map([
            "v": .unsigned(1),
            "cursor": .unsigned(cursor),
            "ts": .unsigned(UInt64(Self.now.timeIntervalSince1970)),
            "type": .text(type),
            "payload": .map(payload),
            "issuer_m_id": .text("m_founder"),
            "signature": .bytes(Data(repeating: 0xEE, count: 64)),
        ])
    }

    private static func response(
        events: [HouseholdCBORValue],
        nextCursor: UInt64
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "events": .array(events),
            "next_cursor": .unsigned(nextCursor),
        ]))
    }

    private struct TransportDrop: Error {}

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

    actor EventVerifierRecorder {
        private(set) var events: [OwnerEventsLongPoll.OwnerEvent] = []

        func record(_ event: OwnerEventsLongPoll.OwnerEvent) {
            events.append(event)
        }
    }
}
