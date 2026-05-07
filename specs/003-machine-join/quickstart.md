# Phase 3 — Machine Join Quickstart

**Audience**: developers picking up Phase 3 (machine-join on Soyeht iPhone) work, or running the Phase 3 test suite locally.

**Status snapshot** (as of branch `003-machine-join-4`): Phases 1 and 2 are landed; Phase 1.5 design artifacts and Phase 3+ stories are partially landed (see `tasks.md` for the live checklist).

---

## 1. Repo layout for Phase 3

```
Packages/SoyehtCore/Sources/SoyehtCore/
├── Household/
│   ├── BIP39Wordlist.swift               # Pinned 2048-word list loader
│   ├── CRLStore.swift                    # Keychain-backed revocation store
│   ├── HouseholdCBOR.swift               # Canonical CBOR encoders (RFC 8949 §4.2.1)
│   ├── HouseholdMembershipStore.swift    # Gossip-driven member set (sibling actor)
│   ├── JoinRequestEnvelope.swift         # Unified Bonjour + QR envelope
│   ├── JoinRequestQueue.swift            # FSM queue (pending/inFlight) with TTL
│   ├── JoinRequestSafeRenderer.swift     # Bidi/control-char neutralizer
│   ├── MachineCertValidator.swift        # CBOR + ECDSA + CRL check
│   ├── MachineJoinError.swift            # Typed error surface (US3)
│   ├── OperatorAuthorizationSigner.swift # Biometric-gated SE signer
│   ├── OperatorFingerprint.swift         # BLAKE3-256 → 66-bit → 6 BIP-39 words
│   ├── PairMachineQR.swift               # FR-029 challenge-sig verifying parser
│   └── …
├── Networking/
│   ├── HouseholdGossipSocket.swift       # WS lifecycle + cursor resume
│   └── Phase3WireClient.swift            # CBOR-only Phase 3 endpoint client
└── Resources/Wordlists/
    └── bip39-en.txt                      # Pinned BIP-0039 English (see §6)
```

Phase 3 *App-layer* code (coordinators, view models, views) lives under
`TerminalApp/Soyeht/Household/` and is being added incrementally per the US1/US2/US3 phases in `tasks.md`.

---

## 2. Dev household bootstrap

The fastest way to land in a "household exists, iPhone is paired" state for Phase 3 work is to run the Phase 2 owner-pairing flow against a dev theyOS server, which yields a `HouseholdSession` with `OwnerIdentityKey` pinned in the Secure Enclave.

1. Boot a dev theyOS server (production: `bignix@192.168.15.16`; dev: see `MEMORY.md` reference for the local setup).
2. Build and run the iOS app on iPhone Simulator (`iPhone 16` is the default scheme):
   ```sh
   xcodebuild -project TerminalApp/Soyeht.xcodeproj \
              -scheme Soyeht \
              -destination 'platform=iOS Simulator,name=iPhone 16' \
              build
   ```
3. Open Settings → Server pairing, scan the `soyeht://household/pair-device` QR rendered by the dev server's owner-pairing CLI. The first-owner flow lands an `ActiveHouseholdState` in Keychain.
4. Confirm via `HouseholdSessionStore.activeSession` that `hh_id` is non-nil and `OwnerIdentityKey` returns a verified attestation.

For unit testing without a server, build `JoinRequestEnvelope` and `MachineCert` directly via the helpers in
`Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdTestFixtures.swift`.

---

## 3. Simulating a Bonjour-shortcut join request (US1)

The on-device flow is:

```
[Mac broadcasts pair-machine] → [iPhone OwnerEventsLongPoll picks up OwnerEvent]
        → [JoinRequestQueue.enqueue]
        → [JoinRequestConfirmationView renders fingerprint]
        → [biometric → OperatorAuthorizationSigner]
        → [Phase3WireClient.POST → Mac]
        → [Mac broadcasts machine_added → HouseholdGossipConsumer applies]
```

`JoinRequestConfirmationView` and the live `OwnerEventsLongPoll`/consumer are
not yet implemented (T032/T024/T034 — see `tasks.md`). For unit tests today,
you can simulate every other link in the chain. The queue + signer + renderer
+ fingerprint paths are exercised in `JoinRequestQueueTests`,
`OperatorAuthorizationSignerTests`, `OperatorFingerprintTests`, and
`JoinRequestSafeRendererTests`.

To assemble a synthetic envelope for ad-hoc work (matches the real init at
`Packages/SoyehtCore/Sources/SoyehtCore/Household/JoinRequestEnvelope.swift`):

```swift
let envelope = JoinRequestEnvelope(
    householdId: householdId,
    machinePublicKey: machineSec1,
    nonce: Data(count: 16),
    rawHostname: "studio.local",
    rawPlatform: "macos",
    candidateAddress: "100.64.10.2",
    ttlUnix: UInt64(Date().addingTimeInterval(300).timeIntervalSince1970),
    challengeSignature: signature,           // 64-byte P-256 ECDSA r||s
    transportOrigin: .bonjourShortcut,        // or .qrLAN / .qrTailscale
    receivedAt: Date()
)
let queue = JoinRequestQueue()
await queue.enqueue(envelope)
guard let claimed = await queue.claim(idempotencyKey: envelope.idempotencyKey) else { return }
// → biometric, sign, POST, then await queue.confirmClaim(idempotencyKey:)
```

---

## 4. Simulating a remote-QR join request (US2)

The QR variant differs only at the front edge: a `pair-machine` URL is parsed
via `PairMachineQR` (T006), which **locally verifies** the challenge_sig under
`m_pub` before producing an envelope (FR-029, anti-phishing). Construction of
the envelope and downstream flow is identical to US1.

To produce a valid synthetic `pair-machine` URL for tests, see
`PairMachineQRTests` for the canonical signing recipe (deterministic CBOR
`JoinChallenge` per RFC 8949 §4.2.1, P-256 ECDSA `r||s` under the candidate
machine's key).

The APNS opaque-tickle path (FR-004) feeds the same long-poll fetch — the
APNS payload is byte-equal to `{"v":1}` and is **never** trusted for content;
arrival only schedules a fetch. See `tasks.md` T044a for the byte-equality
invariant test.

---

## 5. Exercising failure paths (US3)

Failure scenarios sweep:

| Scenario                                        | Test surface                                      |
|-------------------------------------------------|---------------------------------------------------|
| Malformed/expired/wrong-version `pair-machine`  | `PairMachineQRTests`                              |
| Tampered hostname/platform (FR-029 anti-phish)  | `PairMachineQRTests` (signature verification)     |
| Adversarial bidi/control chars in display       | `JoinRequestSafeRendererTests`                    |
| TTL straddle on confirm (5-min hard window)     | `JoinRequestQueueTests` (FR-012 confirm path)     |
| Biometric cancel / lockout (non-terminal)       | `JoinRequestQueueTests.revertClaim` + signer      |
| Terminal failures (hhMismatch, certFail, etc.)  | `JoinRequestQueueTests.failClaim`                 |
| Tampered MachineCert in gossip                  | `MachineCertValidatorTests`                       |
| CBOR canonicalization drift                     | `HouseholdCBORTests`                              |

`MachineJoinError` (T048) is the single typed surface; every public failure
path in the stack currently returns one of its cases. The
`NonTerminalFailureReason` subset enum gates `JoinRequestQueue.revertClaim` at
compile time so terminal errors cannot be passed there. See
`MachineJoinErrorTests` for the adapter exhaustiveness sentinels.

---

## 6. BIP-39 wordlist cross-repo binding (SC-004 / T055)

The fingerprint encoding (`OperatorFingerprint`) selects 6 words from the
**official BIP-0039 English wordlist**. iSoyehtTerm and theyos MUST hold the
same 2048 words byte-for-byte; otherwise the iPhone would render different
words than what the candidate machine speaks at the human, defeating the
anti-phishing guarantee.

Pinned to canonical Bitcoin BIPs upstream (`bitcoin/bips:bip-0039/english.txt`):

| Repo         | Path                                                                                                | SHA-256                                                            | Lines |
|--------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|-------|
| iSoyehtTerm  | `Packages/SoyehtCore/Sources/SoyehtCore/Resources/Wordlists/bip39-en.txt`                           | `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda` | 2048  |
| theyos       | `admin/rust/household-rs/src/bip39_wordlist.rs` (header-recorded SHA of source)                     | `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda` | 2048 entries  |

Verify with:

```sh
shasum -a 256 Packages/SoyehtCore/Sources/SoyehtCore/Resources/Wordlists/bip39-en.txt
grep "SHA-256" /Users/macstudio/Documents/theyos/admin/rust/household-rs/src/bip39_wordlist.rs
```

Both must print the same hash. **Do not regenerate the file.** If the canonical
wordlist ever rotates upstream, both repos must rotate together in a single
co-versioned change.

---

## 7. Replaying gossip events

`HouseholdGossipSocket` (T022) wraps `URLSessionWebSocketTask` with ping/pong
and exponential-backoff cursor-resume reconnect. Its tests
(`HouseholdGossipSocketTests`) drive it against an in-process stub WS server.

Once `HouseholdGossipConsumer` lands (T024, blocked on the theyos contract),
the consumer will validate inbound `machine_added` / `machine_revoked` events
through `MachineCertValidator` and apply them to `HouseholdMembershipStore` /
`CRLStore` reactively. Today, you can test consumer-shaped logic by feeding
fixtures directly into `MachineCertValidator` and asserting the membership
store mutates as expected via the `AsyncStream` it publishes.

---

## 8. Cross-repo sync gates

Run `swift test --package-path Packages/SoyehtCore` to validate everything
that is local-only. The following integration-shaped work is gated on the
matching theyos surface shipping (track in `tasks.md`):

- **T024/T025** — gossip consumer contract & WS server
- **T032** — owner-events long-poll endpoint shape
- **T042-T044c** — APNS sender + register/deregister + leader-election failover
- **T021c/d** — `GET /api/v1/household/snapshot` signed bundle

When upstream lands, vendor the matching contract under
`specs/003-machine-join/contracts/` per the rules in
`Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/MachineJoin/README.md`
(byte-identical, hash-verified).

---

## 9. Running the test suite

```sh
swift test --package-path Packages/SoyehtCore                 # core unit tests
xcodebuild test -project TerminalApp/Soyeht.xcodeproj \
                -scheme Soyeht \
                -destination 'platform=iOS Simulator,name=iPhone 16'  # app tests
```

Filter to a single test for fast iteration:

```sh
swift test --package-path Packages/SoyehtCore \
           --filter JoinRequestQueueTests
```
