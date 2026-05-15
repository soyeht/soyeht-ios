import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// **T031a** — confirmation-card fluidity invariants.
///
/// SC-017: ≤ 0.4 s p95 from long-poll-arrival (or QR-detect) to the
/// confirmation card being visible. The card-visible boundary in
/// production is when `JoinRequestConfirmationCardHost` builds the
/// `JoinRequestConfirmationViewModel` for the queued envelope and the
/// view body renders. We measure the underlying VM-construction work
/// (BIP39 fingerprint derivation + safe rendering + cursor seeding +
/// state) which is the only synchronous cost the host pays — anything
/// else is the SwiftUI view body, which the host renders on the next
/// run-loop tick after the snapshot lock lands.
///
/// SC-018: 0.6–1.0 s perceived duration from operator's Confirm tap to
/// card dismiss. The View runs a 600 ms checkmark transition before it
/// calls `viewModel.dismiss()` — the underlying VM must therefore
/// reach `.succeeded` quickly enough that the *perceived* duration is
/// governed by the animation, not by VM bookkeeping. We assert that
/// `.pending → .succeeded` completes well below the 600 ms animation
/// floor under deterministic stubs, leaving the visible 0.6–1.0 s window
/// to the `JoinRequestConfirmationView` checkmark transition.
@MainActor
final class JoinRequestConfirmationFluidityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// SC-017: card-presentation latency p95 < 0.4 s.
    /// Builds 50 ViewModels from settled queue entries and asserts the
    /// 95th-percentile construction time stays inside the budget.
    func testCardPresentationLatencyP95Under400Milliseconds() async throws {
        let sampleCount = 50
        let queue = JoinRequestQueue()
        let wordlist = try BIP39Wordlist()

        var envelopes: [JoinRequestEnvelope] = []
        envelopes.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let candidateKey = try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: UInt8(0x40 &+ index), count: 32)
            )
            let envelope = try MachineJoinTestFixtures.bonjourJoinRequestEnvelope(
                candidatePrivateKey: candidateKey,
                nonce: Data(repeating: UInt8(0xA0 &+ (index % 16)), count: 32),
                hostname: "studio-\(index).local",
                platform: "macos",
                ttlUnix: UInt64(now.timeIntervalSince1970) + 240,
                householdId: "hh_test",
                receivedAt: now
            )
            // Each envelope must be unique because `JoinRequestQueue` keys
            // by `(householdId, m_pub, nonce)` — varying `m_pub` per
            // sample (different candidate key) gives 50 independent
            // entries the VM constructor can derive a fingerprint from.
            await queue.enqueue(envelope, cursor: UInt64(index))
            envelopes.append(envelope)
        }

        var samples: [TimeInterval] = []
        samples.reserveCapacity(sampleCount)
        for envelope in envelopes {
            let start = Self.steadyClockSeconds()
            _ = try JoinRequestConfirmationViewModel(
                envelope: envelope,
                cursor: 0,
                queue: queue,
                wordlist: wordlist,
                nowProvider: { self.now },
                signAction: { _, _ in
                    // The fluidity assertion only covers presentation —
                    // the sign closure should never fire here.
                    XCTFail("signAction called during card-presentation latency measurement")
                    throw MachineJoinError.signingFailed
                },
                submitAction: { _, _ in }
            )
            samples.append(Self.steadyClockSeconds() - start)
        }

        let sorted = samples.sorted()
        let p95Index = max(0, min(sorted.count - 1, Int(ceil(0.95 * Double(sorted.count))) - 1))
        let p95 = sorted[p95Index]
        XCTAssertLessThan(
            p95,
            0.4,
            "SC-017 violation: p95 card-presentation latency \(p95)s exceeds 0.4 s. Sorted samples: \(sorted)"
        )
    }

    /// SC-018: the underlying VM `.pending → .succeeded` transition must
    /// complete fast enough that the perceived 0.6–1.0 s confirm-to-
    /// dismiss window is governed by the View's 600 ms checkmark
    /// animation, not by VM bookkeeping. We assert the VM transition
    /// happens well below the 600 ms animation floor (≤ 0.2 s under
    /// deterministic stubs); the View layer adds the visual hold.
    func testConfirmToSucceededTransitionWellBelowSixHundredMilliseconds() async throws {
        let candidateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x99, count: 32))
        let envelope = try MachineJoinTestFixtures.bonjourJoinRequestEnvelope(
            candidatePrivateKey: candidateKey,
            nonce: Data(repeating: 0xCD, count: 32),
            ttlUnix: UInt64(now.timeIntervalSince1970) + 240,
            householdId: "hh_test",
            receivedAt: now
        )
        let queue = JoinRequestQueue()
        await queue.enqueue(envelope, cursor: 7)

        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x88, count: 32))
        let ownerIdentity = try InMemoryOwnerIdentityKey(
            publicKey: ownerKey.publicKey.compressedRepresentation,
            keyReference: "fluidity-owner",
            signer: { payload in
                try ownerKey.signature(for: payload).rawRepresentation
            }
        )
        let viewModel = try JoinRequestConfirmationViewModel(
            envelope: envelope,
            cursor: 7,
            queue: queue,
            wordlist: BIP39Wordlist(),
            nowProvider: { self.now },
            signAction: { claimed, cursor in
                try OperatorAuthorizationSigner().sign(
                    envelope: claimed,
                    cursor: cursor,
                    ownerIdentity: ownerIdentity,
                    localHouseholdId: "hh_test",
                    now: self.now
                )
            },
            submitAction: { _, _ in
                // Production submitAction is a CBOR POST; under the
                // fluidity contract the network round-trip is the
                // dominant cost (TLS handshake amortised). Tests use a
                // no-op so the measurement isolates VM bookkeeping —
                // queue claim, state transitions, observer publication
                // — from network latency.
            }
        )

        let start = Self.steadyClockSeconds()
        await viewModel.confirm()
        let elapsed = Self.steadyClockSeconds() - start

        XCTAssertEqual(viewModel.state, .succeeded)
        XCTAssertLessThan(
            elapsed,
            0.2,
            "SC-018 violation: VM `.pending → .succeeded` took \(elapsed)s; the perceived 0.6–1.0 s window must be set by the View animation, not by VM bookkeeping"
        )
    }

    /// Microsecond-resolution wall-clock reading. The fluidity budgets
    /// (≤0.4 s p95, ≤0.2 s for VM bookkeeping) sit several orders of
    /// magnitude above `Date()`'s resolution, so a `Date()`-based delta
    /// is precise enough without dragging in `mach_absolute_time` /
    /// `ContinuousClock` API surface noise.
    private static func steadyClockSeconds() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }
}
