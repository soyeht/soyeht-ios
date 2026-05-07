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

        let firstClaim = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        let secondClaim = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

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
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

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
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

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

    /// Defends against the FR-012 hard-TTL bypass: a card left open past TTL
    /// MUST NOT yield an envelope to the operator-authorization signer, even
    /// if no lazy `pendingEntries(now:)` read has run yet.
    @Test func claimReturnsNilForExpiredEnvelopeAndPublishesExpired() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope(ttlOffsetSeconds: 60)  // alive at `now`
        await queue.enqueue(env)
        let stream = await queue.events()

        let collector = Task<[JoinRequestQueue.Event], Never> {
            var collected: [JoinRequestQueue.Event] = []
            for await event in stream {
                collected.append(event)
                if collected.count == 1 { break }
            }
            return collected
        }

        // Operator drifts past TTL before tapping Confirm.
        let claimAttempt = await queue.claim(
            idempotencyKey: env.idempotencyKey,
            now: Self.now.addingTimeInterval(120)
        )
        #expect(claimAttempt == nil, "expired envelope MUST NOT be returned to the signer")

        let events = await collector.value
        #expect(events == [.removed(idempotencyKey: env.idempotencyKey, reason: .expired)])
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    /// Regression: `pendingEntries` previously mutated `entries` while
    /// iterating its `.values` view, which Swift documents as undefined
    /// behavior (the iterator can skip entries or trap when the dictionary
    /// reorganizes its storage). The single-entry test masked the bug; this
    /// test exercises the path with multiple expired entries to keep the
    /// hot path correct.
    @Test func pendingEntriesEvictsAllExpiredEntriesWithoutCorruption() async throws {
        let queue = JoinRequestQueue()
        let firstExpired = Self.envelope(nonce: 0x01, ttlOffsetSeconds: -10)
        let secondExpired = Self.envelope(nonce: 0x02, ttlOffsetSeconds: -20)
        let thirdExpired = Self.envelope(nonce: 0x03, ttlOffsetSeconds: -30)
        let alive = Self.envelope(nonce: 0x04, ttlOffsetSeconds: 60)

        await queue.enqueue(firstExpired)
        await queue.enqueue(secondExpired)
        await queue.enqueue(thirdExpired)
        await queue.enqueue(alive)

        let pending = await queue.pendingEntries(now: Self.now)

        #expect(pending.map(\.idempotencyKey) == [alive.idempotencyKey])
        #expect(await queue.contains(idempotencyKey: firstExpired.idempotencyKey) == false)
        #expect(await queue.contains(idempotencyKey: secondExpired.idempotencyKey) == false)
        #expect(await queue.contains(idempotencyKey: thirdExpired.idempotencyKey) == false)
        #expect(await queue.contains(idempotencyKey: alive.idempotencyKey) == true)
    }

    /// Each expired entry MUST emit exactly one `.expired` event — no
    /// dupes (would happen if an iterator visited a slot twice after
    /// reorganization) and no skips (would happen if an iterator advanced
    /// past a slot the previous removal vacated).
    // MARK: - T050 — failure-path cleanup

    /// Failure paths (biometric cancel, network drop, cert validation
    /// failure, hh-mismatch) MUST clear the pending entry and emit a typed
    /// `.failed(error)` event so the home view's stack collapses in one
    /// render cycle.
    @Test func failClaimRemovesEntryAndYieldsFailedEvent() async throws {
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
        let cleared = await queue.failClaim(
            idempotencyKey: env.idempotencyKey,
            error: .biometricCancel
        )
        #expect(cleared == true)

        let events = await collector.value
        #expect(events == [
            .added(env),
            .removed(idempotencyKey: env.idempotencyKey, reason: .failed(.biometricCancel)),
        ])
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    /// `failClaim` is idempotent: a second call after the entry is already
    /// gone returns false without re-emitting an event.
    @Test func failClaimUnknownKeyReturnsFalse() async throws {
        let queue = JoinRequestQueue()
        let result = await queue.failClaim(
            idempotencyKey: "missing-key",
            error: .networkDrop
        )
        #expect(result == false)
    }

    /// FR-009 + spec.md edge cases — a failed path MUST NOT poison the
    /// candidate's recovery: the next QR (with a fresh nonce, hence a fresh
    /// idempotency key) MUST enqueue successfully even though the previous
    /// attempt for the same `(hh_id, m_pub)` pair failed.
    @Test func failureDoesNotBlacklistCandidateForFreshQR() async throws {
        let queue = JoinRequestQueue()
        let original = Self.envelope(nonce: 0x01, machineKeyByte: 0xAA)
        await queue.enqueue(original)
        await queue.failClaim(
            idempotencyKey: original.idempotencyKey,
            error: .certValidationFailed(reason: .signatureInvalid)
        )

        // Same (hh_id, m_pub) but fresh nonce — emulates the candidate
        // tapping "Generate new QR" on the Mac after the first attempt
        // failed mid-flight.
        let regenerated = Self.envelope(nonce: 0x02, machineKeyByte: 0xAA)
        let inserted = await queue.enqueue(regenerated)

        #expect(inserted == true, "failure path MUST NOT blacklist (hh_id, m_pub); a fresh nonce must enqueue")
        let pending = await queue.pendingEntries(now: Self.now)
        #expect(pending.map(\.idempotencyKey) == [regenerated.idempotencyKey])
    }

    @Test func pendingEntriesPublishesOneExpiredEventPerExpiredEntry() async throws {
        let queue = JoinRequestQueue()
        let firstExpired = Self.envelope(nonce: 0x01, ttlOffsetSeconds: -10)
        let secondExpired = Self.envelope(nonce: 0x02, ttlOffsetSeconds: -10)
        let thirdExpired = Self.envelope(nonce: 0x03, ttlOffsetSeconds: -10)
        await queue.enqueue(firstExpired)
        await queue.enqueue(secondExpired)
        await queue.enqueue(thirdExpired)

        let stream = await queue.events()
        let collector = Task<Set<String>, Never> {
            var ids: Set<String> = []
            var count = 0
            for await event in stream {
                if case .removed(let key, .expired) = event {
                    ids.insert(key)
                    count += 1
                    if count == 3 { break }
                }
            }
            return ids
        }

        _ = await queue.pendingEntries(now: Self.now)
        let observed = await collector.value
        #expect(observed == [firstExpired.idempotencyKey, secondExpired.idempotencyKey, thirdExpired.idempotencyKey])
    }
}
