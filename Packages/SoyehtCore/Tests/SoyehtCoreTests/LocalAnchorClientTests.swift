import Foundation
import Testing
@testable import SoyehtCore

@Suite("LocalAnchorClient")
struct LocalAnchorClientTests {
    private static let address = "100.82.47.115:8091"
    private static let secret = Data(repeating: 0xAA, count: 32)
    private static let hhId = "hh_eeit7s5ak64oy4cr"
    private static let hhPub = HouseholdTestFixtures.publicKey(byte: 0x42)

    private static func ackBody() -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
    }

    private static func httpResponse(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/cbor"]
        )!
    }

    private static func errorEnvelope(code: String, message: String? = nil) -> Data {
        var map: [String: HouseholdCBORValue] = ["v": .unsigned(1), "error": .text(code)]
        if let message {
            map["message"] = .text(message)
        }
        return HouseholdCBOR.encode(.map(map))
    }

    @Test func endpointBuilderProducesPlainHTTPURLWithCorrectPath() {
        let url = LocalAnchorClient.endpointURL(candidateAddress: "100.82.47.115:8091")
        #expect(url?.absoluteString == "http://100.82.47.115:8091/pair-machine/local/anchor")
    }

    @Test func endpointBuilderHandlesAddressWithoutPort() {
        let url = LocalAnchorClient.endpointURL(candidateAddress: "candidate.local")
        #expect(url?.absoluteString == "http://candidate.local/pair-machine/local/anchor")
    }

    @Test func successfulAnchorReturnsWithoutThrowing() async throws {
        let url = URL(string: "http://\(Self.address)/pair-machine/local/anchor")!
        let body = HouseholdCBOR.localAnchor(
            anchorSecret: Self.secret,
            householdId: Self.hhId,
            householdPublicKey: Self.hhPub
        )
        let recorded = ActorBox<URLRequest?>(nil)
        let client = LocalAnchorClient(
            transport: { request in
                await recorded.set(request)
                return (Self.ackBody(), Self.httpResponse(url, status: 200))
            },
            sleeper: { _ in }
        )

        try await client.pinAnchor(
            candidateAddress: Self.address,
            anchorSecret: Self.secret,
            householdId: Self.hhId,
            householdPublicKey: Self.hhPub
        )

        let captured = await recorded.get()
        #expect(captured?.url == url)
        #expect(captured?.httpMethod == "POST")
        #expect(captured?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(captured?.value(forHTTPHeaderField: "Accept") == "application/cbor")
        #expect(captured?.httpBody == body)
    }

    @Test func authoritative401SurfacesServerErrorWithoutRetry() async {
        let url = URL(string: "http://\(Self.address)/pair-machine/local/anchor")!
        let calls = ActorBox<Int>(0)
        let client = LocalAnchorClient(
            transport: { _ in
                await calls.increment()
                return (Self.errorEnvelope(code: "unauthenticated"), Self.httpResponse(url, status: 401))
            },
            sleeper: { _ in }
        )

        do {
            try await client.pinAnchor(
                candidateAddress: Self.address,
                anchorSecret: Self.secret,
                householdId: Self.hhId,
                householdPublicKey: Self.hhPub
            )
            Issue.record("Expected serverError to throw")
        } catch let error as MachineJoinError {
            switch error {
            case .serverError(let code, _):
                #expect(code == "unauthenticated")
            default:
                Issue.record("Unexpected MachineJoinError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let attempts = await calls.get()
        #expect(attempts == 1, "401 must NOT be retried — the candidate has answered authoritatively")
    }

    @Test func networkDropRetriesUpToBudgetThenSurfaces() async {
        let calls = ActorBox<Int>(0)
        let sleeps = ActorBox<[UInt64]>([])
        let client = LocalAnchorClient(
            transport: { _ in
                await calls.increment()
                throw URLError(.cannotConnectToHost)
            },
            sleeper: { ns in await sleeps.append(ns) }
        )

        do {
            try await client.pinAnchor(
                candidateAddress: Self.address,
                anchorSecret: Self.secret,
                householdId: Self.hhId,
                householdPublicKey: Self.hhPub
            )
            Issue.record("Expected networkDrop after exhausted retries")
        } catch MachineJoinError.networkDrop {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let attempts = await calls.get()
        // Initial attempt + one per backoff slot until budget exhausted.
        #expect(attempts == LocalAnchorClient.backoffScheduleSeconds.count + 1)

        let sleepNs = await sleeps.get()
        let totalSleepSec = sleepNs.reduce(0.0) { $0 + Double($1) / 1_000_000_000.0 }
        #expect(totalSleepSec <= LocalAnchorClient.totalRetryBudgetSeconds + 0.001)
    }

    @Test func transientThenSuccessSucceedsOnRetry() async throws {
        let url = URL(string: "http://\(Self.address)/pair-machine/local/anchor")!
        let calls = ActorBox<Int>(0)
        let client = LocalAnchorClient(
            transport: { _ in
                let n = await calls.incrementAndGet()
                if n < 3 {
                    throw URLError(.networkConnectionLost)
                }
                return (Self.ackBody(), Self.httpResponse(url, status: 200))
            },
            sleeper: { _ in }
        )

        try await client.pinAnchor(
            candidateAddress: Self.address,
            anchorSecret: Self.secret,
            householdId: Self.hhId,
            householdPublicKey: Self.hhPub
        )
        let attempts = await calls.get()
        #expect(attempts == 3)
    }

    @Test func ackWithUnknownKeyFailsClosed() async {
        let url = URL(string: "http://\(Self.address)/pair-machine/local/anchor")!
        let badAck = HouseholdCBOR.encode(.map(["v": .unsigned(1), "extra": .text("nope")]))
        let client = LocalAnchorClient(
            transport: { _ in
                (badAck, Self.httpResponse(url, status: 200))
            },
            sleeper: { _ in }
        )

        do {
            try await client.pinAnchor(
                candidateAddress: Self.address,
                anchorSecret: Self.secret,
                householdId: Self.hhId,
                householdPublicKey: Self.hhPub
            )
            Issue.record("Expected protocol violation on unknown key in ack")
        } catch let MachineJoinError.protocolViolation(detail) {
            // `unexpectedResponseShape` is what the shared key-allowlist
            // surfaces today; pinning `unrecognizedField` would couple
            // the test to a parser internal.
            _ = detail
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

}

actor ActorBox<T: Sendable> {
    private var value: T
    init(_ initial: T) { self.value = initial }
    func get() -> T { value }
    func set(_ v: T) { value = v }
}

extension ActorBox where T == Int {
    func increment() { value = value + 1 }
    func incrementAndGet() -> Int { value = value + 1; return value }
}

extension ActorBox where T == [UInt64] {
    func append(_ x: UInt64) { value.append(x) }
}
