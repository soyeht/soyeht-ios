import Foundation
import Testing
@testable import SoyehtCore

@Suite("JoinRequestQueue")
struct JoinRequestQueueTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func envelope(
        nonce: UInt8 = 1,
        machineKeyByte: UInt8 = 0x01,
        receivedOffsetSeconds: TimeInterval = 0,
        ttlOffsetSeconds: TimeInterval = 300
    ) -> JoinRequestEnvelope {
        JoinRequestEnvelope(
            householdId: "hh_test",
            machinePublicKey: Data([0x02] + [UInt8](repeating: machineKeyByte, count: 32)),
            nonce: Data(repeating: nonce, count: 32),
            rawHostname: "studio.local",
            rawPlatform: "macos",
            candidateAddress: "100.64.1.5:8443",
            ttlUnix: UInt64(now.addingTimeInterval(ttlOffsetSeconds).timeIntervalSince1970),
            challengeSignature: Data(repeating: 0xAA, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: now.addingTimeInterval(receivedOffsetSeconds)
        )
    }

    @Test func enqueueAddsAndYieldsAddedEvent() async throws {
        let queue = JoinRequestQueue()
        let stream = await queue.events()

        let collector = Task<JoinRequestQueue.Event, Never> {
            for await event in stream { return event }
            return .removed(idempotencyKey: "unreachable", reason: .dismissed)
        }

        let env = Self.envelope()
        let inserted = await queue.enqueue(env)
        #expect(inserted == true)

        let observed = await collector.value
        #expect(observed == .added(env))
    }

    @Test func enqueueDeduplicatesByIdempotencyKey() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        let firstInsert = await queue.enqueue(env)
        let secondInsert = await queue.enqueue(env)

        #expect(firstInsert == true)
        #expect(secondInsert == false)
        let pending = await queue.pendingEntries(now: Self.now)
        #expect(pending.count == 1)
        #expect(pending.first == env)
    }

    @Test func claimConsumesEnvelopeOnceForDoubleTapGuard() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)

        let firstClaim = await queue.claim(idempotencyKey: env.idempotencyKey)
        let secondClaim = await queue.claim(idempotencyKey: env.idempotencyKey)

        #expect(firstClaim == env)
        #expect(secondClaim == nil)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    @Test func claimYieldsRemovedClaimedEvent() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        let stream = await queue.events()

        let collector = Task<[JoinRequestQueue.Event], Never> {
            var events: [JoinRequestQueue.Event] = []
            for await event in stream {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey)

        let events = await collector.value
        #expect(events == [
            .added(env),
            .removed(idempotencyKey: env.idempotencyKey, reason: .claimed),
        ])
    }

    @Test func pendingEntriesEvictsAndNotifiesExpiredEntries() async throws {
        let queue = JoinRequestQueue()
        let stream = await queue.events()

        let collector = Task<JoinRequestQueue.Event?, Never> {
            for await event in stream {
                if case .removed(_, .expired) = event { return event }
            }
            return nil
        }

        let env = Self.envelope(ttlOffsetSeconds: -10)  // already expired
        await queue.enqueue(env)
        let pending = await queue.pendingEntries(now: Self.now)

        #expect(pending.isEmpty)
        let removed = await collector.value
        if case .removed(let key, let reason) = removed {
            #expect(key == env.idempotencyKey)
            #expect(reason == .expired)
        } else {
            Issue.record("Expected an expired event")
        }
    }

    @Test func acknowledgeByMachineRemovesAllMatchingEntries() async throws {
        let queue = JoinRequestQueue()
        let firstNonce = Self.envelope(nonce: 0x01, machineKeyByte: 0xAA)
        let secondNonce = Self.envelope(nonce: 0x02, machineKeyByte: 0xAA)
        let differentMachine = Self.envelope(nonce: 0x03, machineKeyByte: 0xBB)

        await queue.enqueue(firstNonce)
        await queue.enqueue(secondNonce)
        await queue.enqueue(differentMachine)

        let removed = await queue.acknowledgeByMachine(publicKey: firstNonce.machinePublicKey)

        #expect(Set(removed) == [firstNonce.idempotencyKey, secondNonce.idempotencyKey])
        let pending = await queue.pendingEntries(now: Self.now)
        #expect(pending.map(\.idempotencyKey) == [differentMachine.idempotencyKey])
    }

    @Test func dismissRemovesEntryAndYieldsDismissedEvent() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        let stream = await queue.events()

        let collector = Task<[JoinRequestQueue.Event], Never> {
            var events: [JoinRequestQueue.Event] = []
            for await event in stream {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        await queue.enqueue(env)
        let dismissed = await queue.dismiss(idempotencyKey: env.idempotencyKey)
        #expect(dismissed == true)

        let events = await collector.value
        #expect(events == [
            .added(env),
            .removed(idempotencyKey: env.idempotencyKey, reason: .dismissed),
        ])
    }

    @Test func dismissUnknownKeyReturnsFalse() async throws {
        let queue = JoinRequestQueue()
        let result = await queue.dismiss(idempotencyKey: "missing-key")
        #expect(result == false)
    }

    @Test func multipleSubscribersEachReceiveAllEvents() async throws {
        let queue = JoinRequestQueue()
        let firstStream = await queue.events()
        let secondStream = await queue.events()

        let firstCollector = Task<Int, Never> {
            var count = 0
            for await _ in firstStream {
                count += 1
                if count == 2 { break }
            }
            return count
        }
        let secondCollector = Task<Int, Never> {
            var count = 0
            for await _ in secondStream {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey)

        #expect(await firstCollector.value == 2)
        #expect(await secondCollector.value == 2)
    }

    @Test func pendingEntriesAreSortedByReceivedAt() async throws {
        let queue = JoinRequestQueue()
        let earliest = Self.envelope(nonce: 0x01, receivedOffsetSeconds: -60)
        let latest = Self.envelope(nonce: 0x02, receivedOffsetSeconds: 0)
        await queue.enqueue(latest)
        await queue.enqueue(earliest)

        let pending = await queue.pendingEntries(now: Self.now)
        #expect(pending.map(\.idempotencyKey) == [earliest.idempotencyKey, latest.idempotencyKey])
    }
}
