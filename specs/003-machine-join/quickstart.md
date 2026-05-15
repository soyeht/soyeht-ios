# Phase 3 — Machine Join Quickstart

**Audience**: developers picking up Phase 3 (machine-join on Soyeht iPhone) work, or running the Phase 3 test suite locally.

**Status snapshot** (as of branch `003-machine-join-6`): Phases 1 and 2 are landed; the local Phase 3 core, owner-events, APNS registration, snapshot bootstrap, gossip consumer, QR parser, and confirmation surfaces are partially landed. See `tasks.md` for the live checklist and hardware-only gates.

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

`OwnerEventsLongPoll`, `JoinRequestConfirmationViewModel`,
`JoinRequestConfirmationView`, `HouseholdSnapshotBootstrapper`, and
`HouseholdGossipConsumer` are implemented and covered by focused tests. The
remaining app-layer gap is the full home-view multi-card presentation and
end-to-end real-device lifecycle wiring (see T036/T037/T039/T058+ in
`tasks.md`). The queue + signer + renderer + fingerprint paths are exercised in
`JoinRequestQueueTests`, `OperatorAuthorizationSignerTests`,
`OperatorFingerprintTests`, and `JoinRequestSafeRendererTests`.

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

The APNS opaque-tickle path (FR-004) feeds the same long-poll fetch. The APNS
payload is byte-equal to `{"aps":{"content-available":1}}` and is **never**
trusted for household content; arrival only schedules a fetch. See `tasks.md`
T044a for the byte-equality invariant test.

---

## 5. Exercising failure paths (US3)

Failure scenarios sweep:

| Scenario                                        | Test surface                                      |
|-------------------------------------------------|---------------------------------------------------|
| Malformed/expired/wrong-version `pair-machine`  | `PairMachineQRTests`                              |
| Tampered hostname/platform (FR-029 anti-phish)  | `PairMachineQRTests` (signature verification)     |
| Adversarial bidi/control chars in display       | `JoinRequestSafeRendererTests`                    |
| TTL straddle on confirm (5-min hard window)     | `JoinRequestQueueTests.confirmClaimAfterTTLPublishesExpiredAndReturnsFalse` (FR-012) |
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

`HouseholdGossipConsumer` validates normalized CBOR `machine_added` /
`machine_revoked` events through an injected event-signature verifier,
`MachineCertValidator`, and root-signed revocation entries. It applies
accepted deltas to `HouseholdMembershipStore` / `CRLStore`, persists the last
applied cursor in UserDefaults, and emits sanitized diagnostics for rejected
events. For local replay, feed `.data` frames built like
`HouseholdGossipConsumerTests.eventFrame(...)` into `consumer.process(...)` or
run a socket stream through `consumer.run(frames:cursorUpdater:onResult:)`.

---

## 8. Cross-repo contract compatibility notes (T054)

Cross-check run on 2026-05-07 against
`/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/`.

| Surface | theyos contract | iOS local contract | Compatibility note |
|---------|-----------------|--------------------|--------------------|
| Pair-machine QR | `pair-machine-url.md` SHA-256 `6824e0a1...e88808f1` | `pair-machine-url.md` SHA-256 `cc7db101...57d6e8a6` | Wire-compatible: same URI, required fields, `JoinChallenge`, signature binding, field validation, and iPhone-to-M1 network hop. iOS local doc adds Swift error taxonomy, fixture strategy, and local max-TTL enforcement. |
| Owner events + approval | `owner-events.md` SHA-256 `22b8f377...74cbddb44` | `owner-events-long-poll.md` + `operator-authorization.md` | Wire-compatible split: `GET /owner-events?since=<CBOR-uint-b64url>`, `204` timeout, CBOR error envelope, `OwnerApprovalContext`, `OwnerApproval`, approval/decline paths, and opaque APNS body all match. |
| Push token registration | `push-token-register.md` SHA-256 `e561c648...d59a4fe6` | `apns-registration.md` SHA-256 `e0b83a4d...d746d531` | Wire-compatible: `POST /api/v1/household/owner-device/push-token`, PoP auth, CBOR `{v, platform="ios", push_token}`, ack `{v, updated_at}`, no `hh_id`. iOS local doc adds lifecycle, dedupe, stale-state recovery, no-deregister behavior, and APNS-disabled fallback. |
| Fingerprint derivation | `fingerprint-derivation.md` SHA-256 `6dafd0ff...78d6df8ed` | local fixture + `OperatorFingerprintTests` | Bound by byte-identical `fingerprint_vectors.json` and pinned BIP-39 wordlist (see §6). |
| JoinRequest / MachineCert | `join-request.md`, `machine-cert-cbor.md` | `data-model.md`, `HouseholdCBORTests`, `MachineCertValidatorTests` | Local implementation matches deterministic CBOR shapes and validation rules; iOS keeps these in model/tests rather than dedicated mirror contract files. |
| Gossip consumer | no dedicated theyos iPhone-consumer contract yet | `household-gossip-consumer.md` | Local contract is derived from protocol §10 and implemented/tested. Re-check when theyos publishes a dedicated gossip consumer contract. |
| Snapshot bootstrap | no dedicated theyos snapshot envelope contract yet | `household-snapshot.md` | Local root-signed snapshot envelope is implemented/tested. Re-check before production rollout if theyos revises the snapshot body/envelope. |

theyos also has `bonjour-pair-machine.md` and `shamir-transition.md`; no
one-to-one iOS local contract file exists yet. Bonjour behavior is represented
through owner-events/JoinRequest convergence. Shamir transition remains outside
the current iOS implementation surface.

---

## 9. Cross-repo sync gates

Run `swift test --package-path Packages/SoyehtCore` to validate everything
that is local-only. The following integration-shaped work is gated on the
matching theyos surface shipping (track in `tasks.md`):

- **T036/T037/T039** — app-layer card stack, lifecycle sequencing, and Story-2 end-to-end path (Story-2 e2e landed 2026-05-07 via `MachineJoinStory2IntegrationTests.swift`).
- **T044c** — elected-sender APNS failover integration: iPhone-side scaffolding landed 2026-05-07 (`MachineJoinFailoverIntegrationTests.swift`); the SC-016 sub-second timing is owned by theyos §13 leader-election and validated only by T061 hardware walkthrough.
- **T031, T031a** — Story-1 e2e + confirmation-card fluidity tests landed 2026-05-07 (`MachineJoinStory1IntegrationTests.swift`, `JoinRequestConfirmationFluidityTests.swift`).
- **T058–T062** — real-hardware LAN/remote/APNS-disabled/failover/tampered-QR walkthroughs (T062 procedure landed; T058–T061 still pending, marked `[ ]` in `tasks.md`). These cannot be automated in CI — they require a physical iPhone, a Mac + a second machine on the household LAN, and (for T060/T061) controlled APNS toggling and Mac power-down.

When upstream lands, vendor the matching contract under
`specs/003-machine-join/contracts/` per the rules in
`Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/MachineJoin/README.md`
(byte-identical, hash-verified).

---

## 10. Hardware walkthroughs (T058–T062)

The walkthroughs in this section are real-device validations of the
architectural invariants the unit suites already cover. Each walkthrough
has a generator step, a delivery step, and an observation log filled
with what was actually seen on hardware. The walkthroughs are intended
to run on the iPhone Devs (UDID `00008110-001A48190231801E` — see
`reference_caio_devices.md`).

### Runbooks

Each walkthrough has a self-contained operator runbook under
`QA/runbooks/`. Run order is intentional — earlier passes are
preconditions of later ones (e.g. T058 must pass before T060's
"foreground-only" assertion is meaningful, because T060 reuses the
T058 candidate machinery).

| Task | Runbook | Spec criterion |
|------|---------|----------------|
| T046 | `QA/runbooks/T046-first-time-owner.md` | SC-006 (first-time owner pairs without password / server choice) |
| T058 | `QA/runbooks/T058-lan-walkthrough.md` | SC-001 (Story 1 LAN, ≤15 s) |
| T059 | `QA/runbooks/T059-tailnet-walkthrough.md` | SC-002 (Story 2 Tailnet, ≤25 s) |
| T060 | `QA/runbooks/T060-apns-disabled-walkthrough.md` | SC-015 (FR-028 OFF, foreground-only success) |
| T061 | `QA/runbooks/T061-elected-sender-failover.md` | SC-016 (sub-second sender failover) |
| T062 | inline §10.1 below | FR-029 (tampered-QR rejection) |

Lab-mode URL generators sit alongside the runbooks:
- `QA/scripts/generate_pair_machine_url.py` — well-formed `pair-machine`
  URL for T058 / T059 (deterministic candidate keypair via
  `--dump-key-pem` if you want to verify the resulting `MachineCert`
  out-of-band).
- `QA/scripts/generate_tampered_pair_machine_url.py` — adversarial
  `pair-machine` URL for T062 (signed hostname differs from URL
  hostname).

### 10.1 T062 — Tampered-QR walkthrough (FR-029 anti-phishing)

**Goal.** Prove that an attacker who captures a legitimate
`pair-machine` QR and rewrites `hostname` (or `platform`) before showing
it to the operator is rejected **on-device, before any network call**.
The candidate signed `JoinChallenge` over the original hostname; the
URL ships the lie. iPhone reconstructs the canonical challenge from URL
fields, ECDSA-verifies against `m_pub`, and surfaces a
`challengeSignatureVerificationFailed` error directly in the
confirmation card error banner.

#### Generator

The Python generator at
`QA/scripts/generate_tampered_pair_machine_url.py` builds a URL whose
`challenge_sig` is valid for `signed-hostname` but whose `hostname`
query item is `tampered-hostname`. It mirrors `HouseholdCBOR.joinChallenge`
byte-for-byte (canonical CBOR map, lex-sorted keys, definite-length).

```sh
uv run --with cbor2 --with cryptography \
    QA/scripts/generate_tampered_pair_machine_url.py \
    --signed-hostname studio.local \
    --tampered-hostname evil.local \
    > /tmp/tampered-pair-machine.url
```

The script also accepts `--platform`, `--transport`, `--addr`, and
`--ttl-seconds` for variations. Defaults match the unit-test fixture
in `PairMachineQRTests.rejectsTamperedHostnameAsAntiPhishing`.

#### Delivery

The `soyeht://` scheme is **not** an OS-registered URL handler; it is
read off a QR image by `QRScannerView`. Encode the URL as a QR using
either tool:

```sh
brew install qrencode  # one-time
qrencode -t ANSIUTF8 -r /tmp/tampered-pair-machine.url
```

or via Python:

```sh
uv run --with qrcode --with pillow python -c \
    'import qrcode,sys; qrcode.make(open("/tmp/tampered-pair-machine.url").read()).save("/tmp/tampered.png")'
open /tmp/tampered.png
```

On iPhone Devs:

1. Pair a household first (the `pair-machine` flow needs an active
   `HouseholdSession` — without one, `QRScannerDispatcher` returns
   `.machineJoin(.hhMismatch)` and never reaches the signature check).
2. From the household home view, tap the `qrcode.viewfinder` button.
3. Point the camera at the QR image displayed on the Mac screen.

#### Expected

- `QRScannerDispatcher.result(for:activeHouseholdId:now:)` returns
  `.failure(.machineJoin(.qrInvalid(reason: .signatureInvalid)))` (the
  parser path is `PairMachineQR.init(url:)` →
  `verifyChallengeSignature` → `challengeSignatureVerificationFailed` →
  `MachineJoinError.qrInvalid(.signatureInvalid)` adapter).
- The card error banner shows the localized
  `MachineJoinError.qrInvalid(.signatureInvalid)` message.
- **Zero outbound traffic.** The dispatcher is fully synchronous up to
  the rejection; no `URLSession` task, no Bonjour publication, no PoP
  signing call. Verifiable by code inspection of `QRScannerDispatcher`
  +  `PairMachineQR.init` (both pure functions).

#### Regression gate

Unit-test gate that fires on every CI run:

```sh
swift test --package-path Packages/SoyehtCore \
    --filter PairMachineQRTests.rejectsTamperedHostnameAsAntiPhishing
swift test --package-path Packages/SoyehtCore \
    --filter PairMachineQRTests.rejectsTamperedPlatformAsAntiPhishing
```

#### Observation log

| Date       | Operator | Device       | App build         | URL signed-hostname | URL tampered-hostname | Result                             | Notes |
|------------|----------|--------------|-------------------|---------------------|------------------------|------------------------------------|-------|
| _pending_  | Owner     | iPhone Devs  | _to fill_         | studio.local        | evil.local             | _to fill (expected: rejected)_     |       |

---

## 11. Running the test suite

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
