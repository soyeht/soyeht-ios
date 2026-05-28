import Foundation
import XCTest

@testable import SoyehtCore

/// Smoke test for the in-process Nostr relay used by E2E tests.
/// Two clients connect to the same relay, one subscribes, the other
/// publishes — the subscriber must receive the event.
final class MockNostrRelayTests: XCTestCase {
    func testEventDeliveredBetweenConnectedClients() async throws {
        let relay = MockNostrRelay()
        let aliceTransport = await relay.accept()
        let bobTransport = await relay.accept()
        let alice = NostrWSSClient(transport: aliceTransport, ackTimeout: 3)
        let bob = NostrWSSClient(transport: bobTransport, ackTimeout: 3)
        try await alice.connect()
        try await bob.connect()

        // Bob subscribes to kind=1 with no tag filter so the matcher
        // is exercised on the simplest path.
        let stream = try await bob.subscribe(id: "bob-1", filter: ["kinds": [1]])

        // Alice publishes a non-Schnorr-signed dummy event. The relay
        // doesn't verify signatures, so any 64-char hex id + sig
        // works for routing.
        let event = NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: UInt64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "hello bob",
            sig: String(repeating: "c", count: 128)
        )

        async let publishFut: Void = alice.publish(event)
        var seen: NostrEvent?
        for await received in stream {
            seen = received
            break
        }
        try await publishFut
        XCTAssertEqual(seen?.content, "hello bob")

        await alice.close()
        await bob.close()
        await relay.shutdown()
    }

    func testStoredEventReplayedToLateSubscriber() async throws {
        let relay = MockNostrRelay()
        let aliceTransport = await relay.accept()
        let alice = NostrWSSClient(transport: aliceTransport, ackTimeout: 3)
        try await alice.connect()

        let event = NostrEvent(
            id: String(repeating: "d", count: 64),
            pubkey: String(repeating: "e", count: 64),
            createdAt: UInt64(Date().timeIntervalSince1970),
            kind: 1059,
            tags: [["p", String(repeating: "f", count: 64)]],
            content: "stored before subscriber",
            sig: String(repeating: "0", count: 128)
        )
        try await alice.publish(event)

        // Late subscriber connects AFTER the event is in the relay's
        // store; replay must deliver it.
        let bobTransport = await relay.accept()
        let bob = NostrWSSClient(transport: bobTransport, ackTimeout: 3)
        try await bob.connect()
        let stream = try await bob.subscribe(
            id: "bob-late",
            filter: ["kinds": [1059], "#p": [String(repeating: "f", count: 64)]]
        )
        var seen: NostrEvent?
        for await received in stream {
            seen = received
            break
        }
        XCTAssertEqual(seen?.content, "stored before subscriber")

        await alice.close()
        await bob.close()
        await relay.shutdown()
    }
}
