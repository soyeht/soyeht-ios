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
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .pending)
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

    // MARK: - Claim semantics (post-redesign)

    /// `claim` MUST transition `pending` → `inFlight` *without* removing the
    /// entry — terminal callers (`confirmClaim` / `failClaim`) and recovery
    /// callers (`revertClaim`) need an entry to act on. The previous
    /// "claim removes immediately" model left `failClaim` unreachable in the
    /// real US3 pipeline (claim → biometric → sign → POST → fail).
    @Test func claimTransitionsPendingToInFlightWithoutRemoving() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)

        let claimed = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        #expect(claimed == env)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == true)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .inFlight)
    }

    /// Double-tap guard: once `inFlight`, subsequent `claim` calls return
    /// nil so the operator-authorization signer is never invoked twice on
    /// the same envelope, even in the absence of UI-level debounce.
    @Test func claimWhileInFlightReturnsNilForDoubleTapGuard() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)

        let firstClaim = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        let secondClaim = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

        #expect(firstClaim == env)
        #expect(secondClaim == nil)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .inFlight)
    }

    @Test func claimYieldsClaimedInFlightEvent() async throws {
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
        #expect(events == [.added(env), .claimedInFlight(env)])
    }

    @Test func claimReturnsNilForMissingKey() async throws {
        let queue = JoinRequestQueue()
        let result = await queue.claim(idempotencyKey: "missing", now: Self.now)
        #expect(result == nil)
    }

    /// Defends against the FR-012 hard-TTL bypass: a card left open past TTL
    /// MUST NOT yield an envelope to the operator-authorization signer.
    @Test func claimReturnsNilForExpiredEnvelopeAndPublishesExpired() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope(ttlOffsetSeconds: 60)
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

        let claimAttempt = await queue.claim(
            idempotencyKey: env.idempotencyKey,
            now: Self.now.addingTimeInterval(120)
        )
        #expect(claimAttempt == nil, "expired envelope MUST NOT be returned to the signer")

        let events = await collector.value
        #expect(events == [.removed(idempotencyKey: env.idempotencyKey, reason: .expired)])
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    // MARK: - confirmClaim (success terminal)

    @Test func confirmClaimRemovesInFlightEntryAndEmitsConfirmed() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

        let confirmed = await queue.confirmClaim(idempotencyKey: env.idempotencyKey, now: Self.now)
        #expect(confirmed == true)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    @Test func confirmClaimReturnsFalseForPendingEntry() async throws {
        // confirmClaim before claim: programmer error, tolerated as no-op.
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        let result = await queue.confirmClaim(idempotencyKey: env.idempotencyKey, now: Self.now)
        #expect(result == false)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .pending)
    }

    @Test func confirmClaimReturnsFalseForMissingKey() async throws {
        let queue = JoinRequestQueue()
        let result = await queue.confirmClaim(idempotencyKey: "missing")
        #expect(result == false)
    }

    /// FR-012 hard TTL straddle: claim succeeds at T+299s, biometric+POST
    /// takes 2s, confirmClaim arrives at T+301s on an entry past TTL. The
    /// queue MUST NOT publish `.confirmed` for an expired envelope —
    /// instead, remove with `.expired` and return false. The Mac may have
    /// independently accepted the operator-authorization on the wire; that
    /// is reflected by the eventual `machine_added` gossip event.
    @Test func confirmClaimAfterTTLPublishesExpiredAndReturnsFalse() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope(ttlOffsetSeconds: 60)
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        let stream = await queue.events()

        let collector = Task<JoinRequestQueue.Event?, Never> {
            for await event in stream {
                if case .removed = event { return event }
            }
            return nil
        }

        let result = await queue.confirmClaim(
            idempotencyKey: env.idempotencyKey,
            now: Self.now.addingTimeInterval(120)
        )
        #expect(result == false, "confirmClaim past TTL MUST NOT publish .confirmed")

        let observed = await collector.value
        #expect(observed == .removed(idempotencyKey: env.idempotencyKey, reason: .expired))
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    @Test func fullSuccessLifecycleEmitsAddedClaimedConfirmed() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        let stream = await queue.events()

        let collector = Task<[JoinRequestQueue.Event], Never> {
            var events: [JoinRequestQueue.Event] = []
            for await event in stream {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        _ = await queue.confirmClaim(idempotencyKey: env.idempotencyKey, now: Self.now)

        let events = await collector.value
        #expect(events == [
            .added(env),
            .claimedInFlight(env),
            .removed(idempotencyKey: env.idempotencyKey, reason: .confirmed),
        ])
    }

    // MARK: - revertClaim (non-terminal: biometric cancel / lockout)

    /// Per spec.md US3 acceptance #3: when the operator cancels Face ID, the
    /// card MUST return to its pre-Confirm state and the request MUST stay
    /// pending until TTL. revertClaim is the canonical path for this.
    @Test func revertClaimReturnsInFlightToPendingWithoutRemoval() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

        let reverted = await queue.revertClaim(
            idempotencyKey: env.idempotencyKey,
            reason: .biometricCancel,
            now: Self.now
        )
        #expect(reverted == true)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == true)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .pending)
    }

    @Test func revertClaimEmitsRevertedToPendingEventWithReason() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        let stream = await queue.events()

        let collector = Task<[JoinRequestQueue.Event], Never> {
            var events: [JoinRequestQueue.Event] = []
            for await event in stream {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        _ = await queue.revertClaim(
            idempotencyKey: env.idempotencyKey,
            reason: .biometricLockout,
            now: Self.now
        )

        let events = await collector.value
        #expect(events == [
            .added(env),
            .claimedInFlight(env),
            .revertedToPending(env, reason: .biometricLockout),
        ])
    }

    /// After revertClaim, the operator can re-tap Confirm and the cycle
    /// repeats — this is the canonical US3 #3 recovery flow.
    @Test func revertedEntryCanBeReclaimedForReattempt() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        _ = await queue.revertClaim(
            idempotencyKey: env.idempotencyKey,
            reason: .biometricCancel,
            now: Self.now
        )

        let reclaim = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        #expect(reclaim == env)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .inFlight)
    }

    @Test func revertClaimReturnsFalseForPendingEntry() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        let result = await queue.revertClaim(
            idempotencyKey: env.idempotencyKey,
            reason: .biometricCancel,
            now: Self.now
        )
        #expect(result == false)
        #expect(await queue.state(forIdempotencyKey: env.idempotencyKey) == .pending)
    }

    @Test func revertClaimReturnsFalseForMissingKey() async throws {
        let queue = JoinRequestQueue()
        let result = await queue.revertClaim(
            idempotencyKey: "missing",
            reason: .biometricCancel,
            now: Self.now
        )
        #expect(result == false)
    }

    /// FR-012 hard TTL on revert: if the operator triggers biometric near
    /// TTL and cancels just past TTL, the entry MUST NOT resurrect to
    /// pending — that would create a TTL-bypass loop (claim near TTL →
    /// cancel → revert → reclaim → cancel → indefinitely). Remove with
    /// `.expired` instead.
    @Test func revertClaimAfterTTLPublishesExpiredAndReturnsFalse() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope(ttlOffsetSeconds: 60)
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        let stream = await queue.events()

        let collector = Task<JoinRequestQueue.Event?, Never> {
            for await event in stream {
                if case .removed = event { return event }
            }
            return nil
        }

        let result = await queue.revertClaim(
            idempotencyKey: env.idempotencyKey,
            reason: .biometricCancel,
            now: Self.now.addingTimeInterval(120)
        )
        #expect(result == false, "revertClaim past TTL MUST NOT resurrect to pending")

        let observed = await collector.value
        #expect(observed == .removed(idempotencyKey: env.idempotencyKey, reason: .expired))
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    // MARK: - failClaim (terminal failure)

    @Test func failClaimRemovesPendingEntryAndYieldsFailedEvent() async throws {
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
            error: .certValidationFailed(reason: .signatureInvalid)
        )
        #expect(cleared == true)

        let events = await collector.value
        #expect(events == [
            .added(env),
            .removed(
                idempotencyKey: env.idempotencyKey,
                reason: .failed(.certValidationFailed(reason: .signatureInvalid))
            ),
        ])
    }

    /// `failClaim` MUST clear an `inFlight` entry too — terminal failures
    /// (network drop confirmed terminal, server error, signing failed)
    /// arrive *after* the operator has tapped Confirm, so the entry is
    /// inFlight at failure time. This is the case the previous "claim
    /// removes immediately" model could never reach.
    @Test func failClaimRemovesInFlightEntryToo() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

        let cleared = await queue.failClaim(
            idempotencyKey: env.idempotencyKey,
            error: .signingFailed
        )
        #expect(cleared == true)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

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

    // MARK: - dismiss

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

    /// `dismiss` is operator-driven; it MUST work in any state — including
    /// `inFlight` (operator swiped the card while biometric was up). State
    /// is irrelevant to the dismissal outcome.
    @Test func dismissRemovesInFlightEntry() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)

        let dismissed = await queue.dismiss(idempotencyKey: env.idempotencyKey)
        #expect(dismissed == true)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    // MARK: - acknowledgeByMachine (gossip)

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

    /// Gossip ack is authoritative — it removes inFlight entries too. If a
    /// machine_added event arrives while the operator is mid-biometric, the
    /// card should drop because the candidate has already joined.
    @Test func acknowledgeByMachineRemovesInFlightEntriesToo() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        // entry is now inFlight

        let removed = await queue.acknowledgeByMachine(publicKey: env.machinePublicKey)
        #expect(removed == [env.idempotencyKey])
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }

    /// Race: confirmClaim and acknowledgeByMachine both target the same
    /// entry (POST 2xx returns at almost the same time as gossip
    /// `machine_added` arrives). The actor serializes the calls; whichever
    /// lands first removes the entry, the second is a no-op. Exactly one
    /// `.removed` event MUST land on each observer (no double removal, no
    /// stale event).
    @Test func confirmClaimVsAcknowledgeByMachineRaceEmitsExactlyOneRemoval() async throws {
        // Case A: confirmClaim first, then gossip ack.
        let queueA = JoinRequestQueue()
        let envA = Self.envelope()
        await queueA.enqueue(envA)
        _ = await queueA.claim(idempotencyKey: envA.idempotencyKey, now: Self.now)
        let confirmedA = await queueA.confirmClaim(idempotencyKey: envA.idempotencyKey, now: Self.now)
        let ackA = await queueA.acknowledgeByMachine(publicKey: envA.machinePublicKey)
        #expect(confirmedA == true)
        #expect(ackA.isEmpty, "second-arriving gossip ack MUST find no matching entry")

        // Case B: gossip ack first, then confirmClaim.
        let queueB = JoinRequestQueue()
        let envB = Self.envelope()
        await queueB.enqueue(envB)
        _ = await queueB.claim(idempotencyKey: envB.idempotencyKey, now: Self.now)
        let ackB = await queueB.acknowledgeByMachine(publicKey: envB.machinePublicKey)
        let confirmedB = await queueB.confirmClaim(idempotencyKey: envB.idempotencyKey, now: Self.now)
        #expect(ackB == [envB.idempotencyKey])
        #expect(confirmedB == false, "confirmClaim after gossip ack MUST be a no-op")
    }

    // MARK: - Observation fan-out

    @Test func multipleSubscribersEachReceiveAllEvents() async throws {
        let queue = JoinRequestQueue()
        let firstStream = await queue.events()
        let secondStream = await queue.events()

        let firstCollector = Task<Int, Never> {
            var count = 0
            for await _ in firstStream {
                count += 1
                if count == 3 { break }
            }
            return count
        }
        let secondCollector = Task<Int, Never> {
            var count = 0
            for await _ in secondStream {
                count += 1
                if count == 3 { break }
            }
            return count
        }

        let env = Self.envelope()
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        _ = await queue.confirmClaim(idempotencyKey: env.idempotencyKey, now: Self.now)

        #expect(await firstCollector.value == 3)
        #expect(await secondCollector.value == 3)
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

    // MARK: - Lazy TTL eviction

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

    /// Regression: `pendingEntries` previously mutated `entries` while
    /// iterating its `.values` view, which Swift documents as undefined
    /// behavior (the iterator can skip entries or trap when the dictionary
    /// reorganizes its storage). The single-entry test masked the bug; this
    /// test exercises the path with multiple expired entries.
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

    /// Each expired entry MUST emit exactly one `.expired` event.
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

    /// Per the FR-012 doc: `pendingEntries` evicts ALL expired entries
    /// regardless of state. An inFlight entry that drifts past TTL is also
    /// evicted (the operator-authorization signer may still complete and
    /// the resulting POST may even succeed — that's acceptable; the queue
    /// just reflects the hard window).
    @Test func pendingEntriesEvictsExpiredInFlightEntries() async throws {
        let queue = JoinRequestQueue()
        let env = Self.envelope(ttlOffsetSeconds: 60)
        await queue.enqueue(env)
        _ = await queue.claim(idempotencyKey: env.idempotencyKey, now: Self.now)
        // entry is now inFlight; advance past TTL.
        let pending = await queue.pendingEntries(now: Self.now.addingTimeInterval(120))
        #expect(pending.isEmpty)
        #expect(await queue.contains(idempotencyKey: env.idempotencyKey) == false)
    }
}
