# Tasks: Phase 3 - Machine Join (Soyeht iPhone)

**Input**: Design documents from `/specs/003-machine-join/`
**Prerequisites**: plan.md, spec.md (clarified), research.md, data-model.md, contracts/, quickstart.md
**Tests**: REQUIRED. Constitution + spec success criteria mandate protocol-boundary tests, cross-repo binding fuzz, idempotency, gossip resume, and APNS-payload sanitization.
**Organization**: Tasks grouped by user story for independent testability. Stories 1 and 2 share most foundational code; Story 3 covers failure paths.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other `[P]` tasks in the same phase when files do not overlap.
- **[Story]**: Maps to User Story 1 (Bonjour shortcut), User Story 2 (remote QR), or User Story 3 (failure recovery) from spec.md.
- Paths are absolute under `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish module surfaces, localization keys, and test fixture scaffolding without writing logic.

- [X] T001 Add `Resources/Wordlists/` to `SoyehtCore` package and register copy resource in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Package.swift`
- [X] T002 [P] Place pinned BIP-0039 English wordlist (2048 lines, byte-identical to theyos's reference) at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Resources/Wordlists/bip39-en.txt` — SHA256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda` (canonical bitcoin/bips upstream)
- [X] T003 [P] Add localized strings for confirmation card, fingerprint label, biometric reason, and failure messages to `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings`
- [X] T004 [P] Add machine-join test fixture directory and README at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/MachineJoin/README.md`
- [X] T005 [P] Vendor `theyos/specs/003-machine-join/tests/fingerprint_vectors.json` byte-identical at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/MachineJoin/fingerprint_vectors.json` (16+ golden vectors, single-locale English; consumed byte-for-byte by `OperatorFingerprintTests` per SC-004) — Vendored 2026-05-07. SHA-256 `09b027c74bb517781745460f4508a96ba1a1c3133b96e90a137b6b5789c1d54f`, 16 tuples, byte-equal with theyos source. Registered as `.copy` resource in `Packages/SoyehtCore/Package.swift` test target. Fixtures README updated with vendoring date and SHA.

---

## Phase 1.5: Design Artifacts (Cross-Repo Binding)

**Purpose**: Produce the design artifacts the plan references and that foundational implementation tasks depend on. Cross-repo contracts here are the source of truth for the joint fingerprint fuzz fixture, canonical CBOR canonicalization, and the household snapshot signature scheme.

- [ ] T005a [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/research.md` covering: BIP39 wordlist pinned-revision strategy + 10-locale rationale, BLAKE3-256 endianness/bit-extraction lock, APNS BG-wakeup latency on iOS 16/17/18, `URLSessionWebSocketTask` resilience patterns, owner-events long-poll cursor semantics, LAError taxonomy and biometric-only policy, household-snapshot signature scheme options
- [ ] T005b [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/data-model.md` with full schemas for `JoinRequestEnvelope`, `OperatorFingerprint`, `OperatorAuthorization`, `JoinRequestQueue`, gossip event variants, `MachineCert` (mirrors §5), `CRLStore`, `RevocationEntry`, `HouseholdSnapshot`
- [ ] T005c [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/pair-machine-url.md` with parser grammar (post-2026-05-06 amendment: `v=1, m_pub, nonce, hostname, platform, transport, addr, challenge_sig, ttl`), JoinChallenge CBOR canonicalization, signature-verification recipe, error taxonomy, golden vectors. Co-versioned with theyos `docs/household-protocol.md` §11.
- [ ] T005d [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/operator-authorization.md` with deterministic CBOR canonicalization rules (key ordering, integer encoding, byte-string encoding), signing input bytes, verification recipe — co-versioned with theyos `qr_signature` definition
- [ ] T005e [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/owner-events-long-poll.md` with HTTP shape, headers, `since` cursor semantics, idle timeout, reconnect rules, fence with APNS-wakeup, `unknown-token` recovery handshake
- [ ] T005f [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/household-gossip-consumer.md` with WebSocket lifecycle, event envelope, accepted event types, cursor persistence rules, MachineCert validation pipeline, CRL ingestion pipeline (snapshot seed + delta from `machine_revoked` events)
- [ ] T005g [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/apns-registration.md` with `POST /apns-register` and `POST /apns-deregister` payload schemas, PoP-auth recipe, token-rotation handshake, `unknown-token` foreground-recovery — co-versioned with theyos
- [ ] T005h [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/contracts/household-snapshot.md` with snapshot envelope, signature verification recipe against `hh_pub`, CRL field schema — co-versioned with theyos

**Checkpoint**: All design artifacts exist and are reviewed cross-repo. Phase 2 implementation tasks may now reference these contracts as their source of truth.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Transport-agnostic protocol surfaces — URI parsing, fingerprint, signer, queue, gossip consumer, MachineCert validator. No story logic begins until this phase is complete.

- [X] T006 [P] Implement `PairMachineQR` parser per protocol §11 (post-2026-05-06 amendment): `v=1, m_pub, nonce, hostname (percent-decode), platform ∈ {macos, linux-nix, linux-other}, transport ∈ {lan, tailscale}, addr, challenge_sig (base64url 64 bytes), ttl`. Parser MUST reconstruct the deterministic CBOR `JoinChallenge = {v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}` (RFC 8949 §4.2.1, lex-ordered keys) and verify `challenge_sig` as P-256 ECDSA `r||s` under `m_pub` LOCALLY before returning a successful parse result; signature verification failure MUST yield a typed `MachineJoinError.qrInvalid(reason: .challengeSigInvalid)` so callers never contact any household member. In `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/PairMachineQR.swift` (covers FR-001 + FR-029). — Parser surfaces `PairMachineQRError`; `MachineJoinError.qrInvalid` mapping happens in T048.
- [X] T007 [P] Add `PairMachineQR` parser + verifier tests covering: valid signed QR; malformed URL; expired ttl; wrong-version; missing-field (each of the 9 required); percent-encoding edge cases in hostname; unsupported `platform` / `transport`; valid CBOR but signature verification failure under `m_pub`; tampered hostname/platform that breaks signature verification (anti-phishing test) — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/PairMachineQRTests.swift` (18 cases)
- [X] T008 [P] Implement `BIP39Wordlist` loader for the official BIP-0039 English wordlist: loads the 2048-word resource, refuses load if file size or word count differs from spec, exposes `word(at index: Int) -> String` returning the canonical English word — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/BIP39Wordlist.swift`
- [X] T009 [P] Add `BIP39Wordlist` tests verifying 2048-entry count, deterministic indexing, and bundle-resource lookup in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/BIP39WordlistTests.swift`
- [X] T010 [P] Implement `OperatorFingerprint` (`BLAKE3-256(M_pub || nonce)` → 66-bit truncation → 6 BIP39 indices) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/OperatorFingerprint.swift`
- [X] T011 [P] Add `OperatorFingerprint` determinism + cross-repo fuzz tests against the 10,000-tuple fixture in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/OperatorFingerprintTests.swift` (covers SC-004) — Determinism + bit-extraction self-vectors landed; cross-repo fixture binding closed 2026-05-07 with `crossRepoFingerprintBindingMatchesTheyos` consuming the 16-tuple T005 fixture (full SC-004 anchor). Note: upstream is currently 16 tuples, not 10k — when theyos expands to the joint 100k cross-locale set the test will continue to consume whatever ships byte-identical.
- [X] T012 [P] Implement `JoinRequestEnvelope` value type unifying Bonjour-shortcut and QR-sourced requests (`hh_id, m_pub, nonce, hostname, platform, candidate_addr, ttl_unix, challenge_sig: [UInt8 × 64], transport_origin, received_at`); raw `hostname` and `platform` strings stored as-received and exposed via accessors that route through `JoinRequestSafeRenderer` for any UI display path; the envelope MUST carry `challenge_sig` whether constructed from a scanned QR or received via owner-events long-poll, so both Story 1 and Story 2 paths converge to the same FR-029 verification — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/JoinRequestEnvelope.swift`
- [X] T012a [P] Implement `JoinRequestSafeRenderer` (Unicode bidi-override neutralization via stripping U+202A..U+202E and U+2066..U+2069; control-character escape for C0/C1 ranges; length cap on hostname/platform with ellipsis applied only at trailing edge so the trustworthy prefix is preserved; idempotent under repeated application) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/JoinRequestSafeRenderer.swift`
- [X] T013 [P] Add `JoinRequestEnvelope` decode/encode/validation tests including hostname/platform safe-rendering invariants (control-char rejection, RTL-override neutralization, idempotent-under-repeat-application, length-cap with trustworthy-prefix preservation) covering FR-006 in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/JoinRequestEnvelopeTests.swift`
- [X] T013a [P] Add `JoinRequestSafeRenderer` adversarial-input fuzz tests covering known bidi-attack vectors (RLO/PDF/RLI/LRI sequences), control-char injection, oversize input, and empty input in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/JoinRequestSafeRendererTests.swift`
- [X] T014 Extend `HouseholdCBOR.swift` with deterministic canonical encoders (RFC 8949 §4.2.1, lex-ordered keys) for: (a) `JoinChallenge = {v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}` — used by FR-029 verification; (b) `OwnerApprovalContext = {v=1, purpose="owner-approve-join", hh_id, p_id, cursor, challenge_sig, timestamp}` — used by FR-008 signing; (c) `OwnerApproval (outer wire body) = {v=1, cursor, approval_sig}`. Field ordering and types pinned cross-repo with theyos contracts/owner-events.md — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdCBOR.swift`
- [X] T015 Add CBOR canonicalization fixture tests covering: key-order determinism, integer/byte-string encoding edge cases, OwnerApprovalContext signing-input bytes byte-equality with theyos reference fixtures, OwnerApproval outer-body round-trip, JoinChallenge byte-equality with theyos canonical-encoder fixtures — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdCBORTests.swift` — Self-determinism + length-first lex-order + content invariants landed; theyos byte-equality fixture pending T005d/T005e upstream.
- [X] T016 [P] Implement `OperatorAuthorizationSigner` (re-uses `OwnerIdentityKey` + `LocalAuthentication.LAContext`, accepts only biometric) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/OperatorAuthorizationSigner.swift` — Biometry enforcement is delegated to `OwnerIdentityKey`'s SE access control (`[.privateKeyUsage, .biometryCurrentSet]`); `OwnerIdentityKeyError.biometryLockout` added.
- [X] T017 [P] Add `OperatorAuthorizationSigner` tests with simulator-injectable biometric stub (success, userCancel, biometryLockout, signature verification under owner cert key) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/OperatorAuthorizationSignerTests.swift`
- [X] T018 [P] Implement `JoinRequestQueue` (TTL-bounded, idempotent over `(hh_id, m_pub, nonce)`, double-tap guard, observer publication) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/JoinRequestQueue.swift`
- [X] T019 [P] Add `JoinRequestQueue` tests for TTL expiry, idempotency, double-tap, and observation-on-machine-added-clear in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/JoinRequestQueueTests.swift`
- [X] T020 [P] Implement `MachineCertValidator` (CBOR decode of MachineCert per §5, P-256 ECDSA verify under stored `hh_pub`, CRL check via `CRLStore.contains(cert.m_id)` emitting a typed validation error when revoked, hh_id match) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/MachineCertValidator.swift`
- [X] T021 [P] Add `MachineCertValidator` tests for valid, tampered, wrong-issuer, wrong-household, and CRL-listed certs in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/MachineCertValidatorTests.swift`
- [X] T021a [P] Implement `RevocationEntry` (codable, signed) and `CRLStore` (Keychain-backed, observable via `@Published` / `AsyncStream`, dedupes on add, persists across launches) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/CRLStore.swift`
- [X] T021b [P] Add `CRLStore` tests for persistence across simulated app restart, dedupe-on-add, observability (subscribers receive each addition once), and Keychain-clear behavior in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/CRLStoreTests.swift`
- [ ] T021c [P] Implement `HouseholdSnapshotBootstrapper` (fetches `GET /api/v1/household/snapshot` per §12, validates the snapshot signature against `hh_pub`, populates `CRLStore` and `HouseholdSession.members` atomically as a single boot-time operation before the gossip consumer starts processing deltas) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdSnapshotBootstrapper.swift`
- [ ] T021d [P] Add `HouseholdSnapshotBootstrapper` tests covering valid snapshot, tampered snapshot, empty CRL, populated CRL, and the 30-day-old-household scenario where the snapshot CRL pre-rejects subsequently-streamed `machine_added` events for revoked machines (covers SC-011) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdSnapshotBootstrapperTests.swift`
- [X] T021e [P] Implement `Phase3WireClient` enforcing the uniform CBOR wire format (FR-030 + FR-031) for all Phase 3 endpoints: send/receive `Content-Type: application/cbor`, parse 4xx/5xx response bodies as deterministic CBOR `{v=1, error=<string>}`, map each typed `error` value to a `MachineJoinError` case, refuse to fall back to JSON parsing on Phase 3 endpoints, surface a typed `MachineJoinError.protocolViolation` if a Phase 3 response arrives with `Content-Type: application/json` — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Networking/Phase3WireClient.swift` — Surfaces `Phase3WireError` (statusError carries `httpStatus`, `code`, `message?`); MachineJoinError mapping happens in T048.
- [X] T021f [P] Add `Phase3WireClient` tests covering: round-trip CBOR success, CBOR-error parsing, JSON-error response refusal, malformed CBOR error body, missing `v` or `error` field, content-type mismatch, byte-by-byte determinism of outbound canonicalization in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/Phase3WireClientTests.swift` (14 cases incl. charset-suffix tolerance + missing-CT refusal)
- [X] T022 Implement `HouseholdGossipSocket` wrapping `URLSessionWebSocketTask` with ping/pong, exponential reconnect, and cursor-resume in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Networking/HouseholdGossipSocket.swift`
- [X] T023 Add `HouseholdGossipSocket` tests using a stub WS server: connect/disconnect/reconnect with cursor, ping/pong, malformed frame rejection in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdGossipSocketTests.swift`
- [ ] T024 Implement `HouseholdGossipConsumer` (event filter for `machine_added`/`machine_revoked`, dedupe-by-id, cursor persistence in UserDefaults, validation through `MachineCertValidator`; on validated `machine_revoked` MUST persist via `CRLStore.append(entry)` and trigger `HouseholdSession.members.remove(m_id)` reactively; on validated `machine_added` MUST append to `HouseholdSession.members` reactively) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdGossipConsumer.swift`
- [ ] T025 Add `HouseholdGossipConsumer` tests for filtering, dedupe (no double-insert across reconnect), cursor persistence, validation rejection, CRL population from `machine_revoked` events, and one-render-cycle reactive UI propagation (covers SC-006, SC-007a, SC-007b, SC-009, SC-012) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdGossipConsumerTests.swift`
- [X] T026 Extend `HouseholdSession` to expose member-mutation API (add/remove) for the gossip consumer and to publish member-update events reactively (`@Published` / `AsyncStream`) for one-render-cycle UI propagation in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdSession.swift` — Implemented as sibling actor `HouseholdMembershipStore` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdMembershipStore.swift` to keep gossip-driven membership state distinct from the keychain-persisted pairing credentials in `ActiveHouseholdState`.
- [X] T027 Add `HouseholdSession` member-mutation tests, including idempotent re-add, revocation removal, observer-fan-out (multiple subscribers each receive every event exactly once), and Phase-2 non-regression (existing pairing/PoP-signing tests still pass) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdSessionTests.swift` — Tests landed at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdMembershipStoreTests.swift` (8 cases, including non-regression on `HouseholdSessionStore`).

**Checkpoint**: All transport-agnostic primitives (parser, fingerprint, signer, queue, gossip consumer, validator) are built and unit-tested without UI or live network.

---

## Phase 3: User Story 1 - Same-LAN machine join via Bonjour shortcut (Priority: P1) MVP

**Goal**: Receive a Bonjour-shortcut-originated join request via the owner-events long-poll, present the confirmation card with the BIP39 fingerprint, biometric-confirm, deliver the operator-authorization to the Mac, and observe the resulting `machine_added` event in the gossip stream.

**Independent Test**: Use stub `OwnerEventsLongPoll` emitting one Bonjour-origin join request, fake biometric, fake gossip emitting matching `machine_added`; verify confirmation card, fingerprint match, operator-authorization payload, idempotency, and `HouseholdSession.members` mutation within latency budget.

### Tests for User Story 1

- [ ] T028 [P] [US1] Add `OwnerEventsLongPoll` foreground-mode tests (long-poll lifecycle, cursor advance, request fan-in to `JoinRequestQueue`) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerEventsLongPollTests.swift`
- [ ] T029 [P] [US1] Add `JoinRequestConfirmationViewModel` tests: card presentation, fingerprint render, biometric success, idempotent double-tap, TTL countdown auto-dismiss in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/JoinRequestConfirmationViewModelTests.swift`
- [ ] T030 [P] [US1] Add `OwnerEventsCoordinator` foreground-arbitration tests (long-poll active when foregrounded, suspended on background) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/OwnerEventsCoordinatorTests.swift`
- [ ] T031 [P] [US1] Add Story 1 end-to-end timing test (Bonjour-origin request → confirm → gossip-applied member, <15s in fault-injection harness) covering SC-001; AND assert via `URLProtocol` recording fixture that outbound traffic during the run is exclusively long-poll, gossip WS, and PoP-signed RPCs — zero polling requests to any household-member endpoint (covers SC-009 + FR-016) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/MachineJoinStory1IntegrationTests.swift`
- [ ] T031a [P] [US1] Add card-presentation-latency test asserting <0.4s p95 from long-poll-arrival or QR-detect to confirmation card visible (covers SC-017) and confirm-to-dismiss perceived duration 0.6–1.0s (covers SC-018) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/JoinRequestConfirmationFluidityTests.swift`

### Implementation for User Story 1

- [ ] T032 [US1] Implement `OwnerEventsLongPoll` Tailscale-routed client: PoP-auth via Phase-2 `HouseholdPoPSigner`; cursor base64url-no-pad CBOR uint per theyos contracts/owner-events.md; long-poll timeout 45s; exponential reconnect on drop; on receiving `OwnerEvent { cursor, type, payload }` for `type == "join-request"`, decode `payload.join_request_cbor` into a `JoinRequestEnvelope`, run FR-029 challenge_sig verification, run FR-029a fingerprint cross-check (re-derive from `m_pub`, bit-equal-check against `payload.fingerprint`, fail with `MachineJoinError.derivationDrift` on mismatch), then enqueue into `JoinRequestQueue` keyed by `(hh_id, m_pub, nonce)`; cursor advances only after successful enqueue (failures stay at last applied cursor and surface as typed errors) — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Networking/OwnerEventsLongPoll.swift`
- [ ] T033 [US1] Implement `OwnerEventsCoordinator` orchestrating foreground long-poll vs. background-suspend in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/OwnerEventsCoordinator.swift`
- [ ] T034 [US1] Implement `JoinRequestConfirmationViewModel` with TTL countdown, idempotency, and biometric reason string in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/JoinRequestConfirmationViewModel.swift`
- [ ] T035 [US1] Implement `JoinRequestConfirmationView`: card UI; 6 BIP-39 English fingerprint words rendered in monospace; hostname/platform via `JoinRequestSafeRenderer` (control-char / RTL-override neutralized); Confirm/Dismiss buttons; light-impact haptic on Confirm tap; medium-impact haptic on biometric success; 0.6 s fingerprint-words → checkmark transition before auto-dismiss; new-member highlight ring (1.0 s scale-in + accent border) coordinated with `HouseholdSession` member-added publisher — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/JoinRequestConfirmationView.swift`
- [ ] T036 [US1] Hook the confirmation card into `HouseholdHomeView` with: custom presentation transition originating from the QR-frame rectangle when QR-initiated (AirDrop-style spatial continuity) or from the top edge when long-poll-initiated; multi-card stacking in iOS Notification Center pattern when concurrent pending requests exist; per-card TTL countdown driven by `JoinRequestQueue` observation — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdHomeView.swift`
- [ ] T037 [US1] Wire post-pairing app lifecycle: on `HouseholdSession` activation, run `HouseholdSnapshotBootstrapper` once (atomic CRL + members seed), THEN start `HouseholdGossipConsumer` (deltas), THEN start `OwnerEventsCoordinator`; on session clear, stop in reverse order — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/SoyehtApp.swift`

**Checkpoint**: Story 1 is independently testable end-to-end with stubbed transports.

---

## Phase 4: User Story 2 - Remote machine join via QR-over-Tailscale (Priority: P2)

**Goal**: Add the QR scan path for `pair-machine` URIs and the APNS-wakeup background path; both must converge to the same `JoinRequestConfirmationView` from Story 1.

**Independent Test**: Scan a synthetic `pair-machine` URI; verify the same confirmation card appears with the same fingerprint algorithm; deliver operator-authorization via Tailscale routing; observe matching gossip event. Separately, simulate APNS silent wakeup while backgrounded; verify the long-poll fetch retrieves the request and the card surfaces on next foreground.

### Tests for User Story 2

- [ ] T038 [P] [US2] Add `QRScannerView` machine-dispatch tests verifying that `/pair-machine` URIs route to the JoinRequest path while `/pair-device` continues to route to Phase 2 in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/QRScannerViewMachineDispatchTests.swift`
- [ ] T039 [P] [US2] Add Story-2 end-to-end test (QR scan → confirmation → gossip-applied member via Tailscale routing, <25s; covers SC-002) AND assert via `URLProtocol` recording fixture zero polling requests during the run (covers SC-009) — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/MachineJoinStory2IntegrationTests.swift` (the verifiable APNS-empty-payload assertion lives in T044a)
- [ ] T040 [P] [US2] Add `OwnerEventsCoordinator` background-arbitration tests (APNS tickle wakes long-poll fetch, no payload trust on APNS itself) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/OwnerEventsCoordinatorTests.swift`

### Implementation for User Story 2

- [ ] T041 [US2] Extend `QRScannerView` path dispatcher to recognize `soyeht://household/pair-machine`, parse via `PairMachineQR`, and emit a JoinRequest envelope in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/QRScannerView.swift`
- [ ] T042 [US2] Implement `ApplicationDelegate+APNS` opaque-tickle handler with explicit payload-stripping assertion (any household-data field MUST trigger an integrity error) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/ApplicationDelegate+APNS.swift`
- [ ] T043 [US2] Implement `APNSRegistrationCoordinator` orchestrating the full lifecycle: (a) initial register on first post-pairing launch via `POST /api/v1/household/apns-register` (PoP-authenticated, body `{p_id, device_token, timestamp, signature}`, no `hh_id`); (b) refresh on iOS token rotation when new token differs from cached (skip identical-token re-registers); (c) deregister via `POST /api/v1/household/apns-deregister` on session clear with best-effort retry up to 24h; (d) auto-re-register on foreground when household reports unknown token (covers FR-023..FR-026 + SC-013/SC-014) — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/APNSRegistrationCoordinator.swift`
- [ ] T043a [P] [US2] Add `APNSRegistrationCoordinator` tests covering: rotation detection, dedupe of identical-token registers, deregister-on-session-clear with retry-on-failure, foreground-recovery handshake when household reports unknown token (covers SC-013 + SC-014) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/APNSRegistrationCoordinatorTests.swift`
- [ ] T044 [US2] Add background-fetch-on-wake path in `OwnerEventsCoordinator` triggered by the APNS handler (does NOT trust the APNS payload; only its arrival as a tickle) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/OwnerEventsCoordinator.swift`
- [ ] T044a [P] [US2] Add APNS-payload-byte-equality test: intercept inbound APNS payload bytes in test harness and assert byte-equality with `b'{"v":1}'` (literal canonical payload per FR-004 + SC-010); test MUST fail if ANY byte differs from the canonical literal, including length differences — in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/APNSPayloadInvariantTests.swift`
- [ ] T044b [US2] Wire "Apple Push Service" into the existing settings infrastructure: (a) add `.householdApplePushService` case to `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Settings/SettingsRoute.swift`; (b) add a labeled row in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Settings/SettingsRootView.swift` that navigates to the new route when the iPhone holds an active `HouseholdSession` (row hidden pre-pairing); (c) implement the detail view at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Settings/HouseholdApplePushServiceView.swift` with a `Toggle` (default ON) bound to a per-household preference; OFF calls `APNSRegistrationCoordinator.suspend()` and falls the iPhone back to foreground-only Tailscale long-poll (covers FR-028 + SC-015); reachable from the household home view in two taps via existing settings entry; preserves FR-019 (no new top-level screen — adds one route case + one row + one detail view to the existing settings surface).
- [ ] T044c [P] [US2] Add elected-sender failover integration test (founding Mac powered down → backup machine takes APNS sender role within 1s per theyos §13 election; Story 1 join still completes in SC-001 budget; covers SC-016) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/MachineJoinFailoverIntegrationTests.swift`

**Checkpoint**: Story 2 is independently testable with stubbed APNS and stubbed Tailscale endpoints.

---

## Phase 5: User Story 3 - Reject and recover from join-request failures safely (Priority: P3)

**Goal**: Every malformed/tampered/expired/biometric-canceled/network-dropped/validation-failed path produces a recoverable, human-readable error and never mutates `HouseholdSession.members`.

**Independent Test**: Sweep the failure matrix from spec.md edge cases; assert no signature is produced, no member is added, no silent retry occurs, and each path renders a localized message.

### Tests for User Story 3

- [ ] T045 [P] [US3] Add `JoinRequestConfirmationViewModel` failure-state tests (biometric cancel, biometric lockout, network drop on submit, hh_id mismatch, fingerprint regeneration after re-fetch differs) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/JoinRequestConfirmationFailureViewModelTests.swift`
- [ ] T046 [P] [US3] Add `HouseholdGossipConsumer` adversarial-event tests covering tampered MachineCert, wrong issuer, wrong household, CRL-listed (covers SC-006) — extend existing test file at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdGossipConsumerTests.swift`
- [ ] T047 [P] [US3] Add `PairMachineQR` rejection-path tests for adversarial hostname/platform, replayed nonce, and TTL-just-expired (covers SC-003) — extend existing test file at `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/PairMachineQRTests.swift`

### Implementation for User Story 3

- [X] T048 [US3] Implement typed `MachineJoinError` (qrInvalid, qrExpired, hhMismatch, biometricCancel, biometricLockout, mac unreachable, networkDrop, certValidationFailed, gossipDisconnect) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/MachineJoinError.swift` — Implemented with nested `QRInvalidReason` / `CertValidationReason` / `ProtocolViolationDetail` and **total** adapter inits from `PairMachineQRError`, `MachineCertError`, `OperatorAuthorizationSignerError`. Includes `protocolViolation`, `derivationDrift`, `serverError(code:message:)`, and `signingFailed` cases referenced by T021e + T032. `QRInvalidReason.schemaUnsupported(version: String?)` preserves the offending version string from `PairMachineQRError.unsupportedVersion`. Sentinel exhaustiveness tests for all three adapter switches. 25 tests in `MachineJoinErrorTests.swift`.
- [ ] T049 [US3] Map `MachineJoinError` cases to localized messages in `Localizable.xcstrings` and surface them in `JoinRequestConfirmationView` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/JoinRequestConfirmationViewModel.swift`
- [X] T050 [US3] Ensure failed paths clear pending queue entries without retry but preserve the candidate's ability to regenerate a fresh QR (no client-side cache poisoning) in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/JoinRequestQueue.swift` — Redesigned `JoinRequestQueue` with explicit `EntryState` (`pending` / `inFlight`) so the failure-path API is reachable in the real US3 pipeline (claim → biometric → sign → POST → fail). `claim` transitions `pending → inFlight` without removing; `confirmClaim(now:)` finalizes success terminally with FR-012 hard-TTL straddle check (drift past TTL → `.expired`, not `.confirmed`); `failClaim` clears any state for terminal failures (`hhMismatch`, `certValidationFailed`, `signingFailed`, `serverError`, etc.); `revertClaim(reason:now:)` returns inFlight → pending for spec.md US3 #3 non-terminal cases — `reason` is typed (`MachineJoinError.NonTerminalFailureReason` with `.biometricCancel` / `.biometricLockout`) so terminal errors can't be passed at compile time, plus FR-012 TTL guard prevents resurrection past TTL. `acknowledgeByMachine` and `pendingEntries(now:)` handle both states. New `Event` variants `claimedInFlight` and `revertedToPending`. Idempotency keying unchanged — fresh nonce always re-enqueues. 39 tests in `JoinRequestQueueTests.swift` covering full lifecycle including TTL straddle on confirm/revert and confirmClaim-vs-gossip race.
- [ ] T051 [US3] Add diagnostic logging hook for rejected gossip events (severity, event id, reason) without leaking sensitive data in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdGossipConsumer.swift`

**Checkpoint**: User Story 3 is independently complete when the failure matrix from spec.md edge cases is fully covered without mutating `HouseholdSession.members`.

---

## Phase 6: Polish, docs, cross-repo binding

- [X] T052 [P] Update `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/README.md` with the machine-join flow summary (no new top-level screens; same scanner; gossip-driven membership) — Added a "Machine join" bullet under Server Management explaining the same-scanner FR-029 anti-phish parser, Bonjour-vs-QR convergence, biometric-gated 6-word fingerprint, and gossip-driven membership; links to `specs/003-machine-join/`.
- [X] T053 [P] Write `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md` covering: dev household bootstrap, simulating Bonjour-shortcut and remote-QR requests, exercising failure paths, replaying gossip — Authored 9-section quickstart: repo layout, dev bootstrap on top of Phase 2 owner-pairing, US1 Bonjour synthesis, US2 QR + APNS opaque-tickle, US3 failure matrix mapping to existing tests, BIP39 cross-repo binding (T055), gossip replay shape, cross-repo sync gate inventory, test commands.
- [ ] T054 [P] Cross-check iOS contracts against `/Users/macstudio/Documents/theyos/specs/003-*/contracts/` and record compatibility notes in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`
- [X] T055 [P] Verify cross-repo BIP39 wordlist version match and check fingerprint-fuzz fixture into both repos with identical content (SC-004) — Wordlist verified byte-equal across repos (SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`, 2048 entries; iSoyehtTerm `Packages/SoyehtCore/Sources/SoyehtCore/Resources/Wordlists/bip39-en.txt` ↔ theyos `admin/rust/household-rs/src/bip39_wordlist.rs` header SHA). Documented in quickstart.md §6 with verification recipe. Fingerprint-fuzz fixture vendoring (T005) remains a separate task — `theyos/specs/003-machine-join/tests/fingerprint_vectors.json` (SHA-256 `09b027c74bb517781745460f4508a96ba1a1c3133b96e90a137b6b5789c1d54f`, 210 lines) now exists upstream and is unblocked.
- [ ] T056 Run `swift test --package-path Packages/SoyehtCore` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`
- [ ] T057 Run `xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht -destination 'platform=iOS Simulator,name=iPhone 16'` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`
- [ ] T058 Run an end-to-end LAN walkthrough on real hardware (Mac Studio + iPhone 16 Pro + a second machine on the household LAN) and record observations in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`
- [ ] T059 Run an end-to-end remote walkthrough on real hardware (Mac Studio + iPhone 16 Pro on Tailnet + a remote candidate not on LAN) and record observations in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`
- [ ] T060 Run an APNS-disabled walkthrough (toggle from FR-028 OFF) on real hardware to validate SC-015 — full Story 1 + Story 2 acceptance with foreground-only long-poll — and record observations in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`
- [ ] T061 Run an elected-sender-failover walkthrough on real hardware (power Mac down mid-flight; verify backup machine takes APNS sender role and Story 1 still completes within SC-016 budget) and record observations in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`
- [ ] T062 Run a tampered-QR walkthrough on real hardware: inject a hand-crafted `pair-machine` URL with hostname/platform mutated post-signing (challenge_sig becomes invalid). Verify iPhone rejects locally with no network call (covers FR-029 + anti-phishing). Record observations in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/003-machine-join/quickstart.md`

---

## Dependency Graph

- T001-T005 are Phase 1 setup; T002-T005 can run in parallel after T001.
- T005a-T005h are Phase 1.5 design artifacts; all parallel; gate Phase 2 implementation tasks that consume their contracts (T014 ↔ T005d, T022/T024 ↔ T005f, T021c ↔ T005h, T032 ↔ T005e, T043 ↔ T005g).
- T006-T027 are foundational. Within Phase 2: T006/T008/T010/T012/T016/T018/T020/T021a/T021c can be written in parallel (different files); T014 depends on existing `HouseholdCBOR.swift` from Phase 2 of feature 002. T020 depends on T021a (CRLStore). T021c depends on T021a + T020. T022/T024 depend on T020 + T021a. T024 depends on T021c (snapshot must seed before deltas apply). T026 depends on T024.
- US1 (T028-T037) depends on Phase 2 complete.
- US2 (T038-T044c) depends on US1 because it reuses `JoinRequestConfirmationView` and `OwnerEventsCoordinator`.
- US3 (T045-T051) depends on US1 + US2 because it sweeps failure paths in surfaces created by both.
- Phase 6 polish/E2E depends on US1+US2+US3.

## Parallel-Execution Notes

- T005a-T005h can all be written in parallel by file (Phase 1.5).
- T006-T013, T021a-T021d can be written in parallel by file (Phase 2).
- T028-T031a can be written in parallel before US1 implementation.
- T038-T040, T043a, T044a, T044c can be written in parallel before US2 implementation.
- T045-T047 can be written in parallel before US3 implementation.
- T052-T055 doc/cross-repo polish tasks parallelize.

## Cross-Repo Sync Gates

These tasks are blocked until theyos has shipped or contracted the matching surface:

- **T005d, T005e, T005g, T005h** — joint authoring with theyos for the four cross-repo contract documents (operator-authorization, owner-events long-poll, APNS registration, household snapshot).
- **T005 (fingerprint fuzz fixture)** — blocked on jointly producing the 100k-tuple cross-locale fixture (10 locales × 10,000) with theyos's reference implementation.
- **T021c-T021d (`HouseholdSnapshotBootstrapper`)** — blocked on theyos shipping `GET /api/v1/household/snapshot` with the agreed signed-bundle envelope.
- **T024-T025 (`HouseholdGossipConsumer`)** — blocked on theyos shipping `GET (WS) /api/v1/household/gossip` with `machine_added` / `machine_revoked` event types per §10.
- **T032 (`OwnerEventsLongPoll`)** — blocked on theyos defining `GET /api/v1/household/owner-events?since=<cursor>` shape.
- **T042-T043 (APNS handler + registration coordinator)** — blocked on theyos implementing the APNS sender side, the device-token registration / deregistration endpoints, and the `unknown-token` recovery handshake.
- **T044c (elected-sender failover)** — blocked on theyos implementing the leader-election protocol §13 with sub-second APNS-sender failover.

## Suggested Implementation Order

1. T001-T005 (Phase 1 setup).
2. T005a-T005h (Phase 1.5 design artifacts; cross-repo).
3. T006-T027 (Phase 2 foundational — no story logic yet, but full CRL + snapshot pipeline).
4. T028-T037 (US1 — full Bonjour-shortcut path with fluidity layer).
5. T038-T044c (US2 — QR + APNS lifecycle + opt-out toggle + failover).
6. T045-T051 (US3 — failure sweep).
7. T052-T062 (polish + cross-repo binding + real-hardware walkthroughs including APNS-disabled, elected-sender-failover, and tampered-QR anti-phishing).
