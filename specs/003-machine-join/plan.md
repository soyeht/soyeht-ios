# Implementation Plan: Phase 3 - Machine Join (Soyeht iPhone)

**Branch**: `003-machine-join` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-machine-join/spec.md`

## Summary

The Soyeht iPhone gains the client half of household machine join, transport-agnostic across LAN-Bonjour-shortcut (Story 1) and remote-QR-over-Tailscale (Story 2). The iPhone receives owner-targeted join-request events via a Hybrid push transport (Tailscale long-poll while foregrounded; APNS opaque wakeup while backgrounded with payload-fetch over Tailscale on wake), surfaces a single confirmation card UI with a 6-word BIP39 fingerprint deterministically derived from `BLAKE3-256(M_pub_SEC1)`, requires Secure Enclave biometric authorization to produce a P-256 ECDSA `qr_signature` per protocol §5, submits that operator-authorization to the Mac, and learns about the resulting `MachineCert` reactively via a household gossip WebSocket consumer scoped to membership events. The iPhone never sees `HH_priv` and never signs `MachineCert` itself; that is the founding Mac's responsibility per protocol §6.

The technical approach extends `SoyehtCore/Household/` with a unified `JoinRequestEnvelope`, fingerprint, authorization signer, and gossip consumer; adds a Tailscale long-poll client and an APNS-wakeup boundary in `SoyehtCore/Networking/`; reuses `QRScannerView` by adding a `/pair-machine` path case; and adds a single confirmation-card surface in the iOS app target. No macOS owner-confirmation surface in this feature. No new top-level screens.

## Technical Context

**Language/Version**: Swift 5.9
**Primary Dependencies**: SwiftUI, AVFoundation, Foundation, Security, CryptoKit, LocalAuthentication, Network framework (`URLSessionWebSocketTask` for gossip; `NWConnection`/`URLSession` long-poll for owner-events), UserNotifications + UNUserNotificationCenter for APNS registration, BLAKE3 (already in `Packages/SoyehtCore`), existing Phase 2 `OwnerIdentityKey`, `PersonCert`, `HouseholdPoPSigner`, `HouseholdSession`, `PairDeviceQR`.
**Storage**: Keychain for owner identity key reference and any cached `OperatorAuthorization` entries (small, TTL-bounded). UserDefaults for gossip cursor (non-secret event-stream offset, can be reset without security impact). `HouseholdSession.members` materialized in-memory and persisted via the existing Phase-2 session store.
**Testing**: `swift test` for `SoyehtCore` (URI parsing, fingerprint determinism, CBOR canonicalization, gossip event validation, idempotency, queue TTL); XCTest in `TerminalApp/Soyeht.xcodeproj` for confirmation card view-model behavior, scanner dispatch, biometric-cancel, network-drop. Test doubles: fake gossip stream emitting deterministic event sequences, in-memory `JoinRequestQueue`, stub APNS-wakeup notifier.
**Target Platform**: iOS 16+. macOS Soyeht imports `SoyehtCore` and benefits from gossip-driven member updates read-only; macOS does NOT import any owner-confirmation UI from this feature.
**Project Type**: iOS app + shared Swift package.
**Performance Goals**: Bonjour-shortcut Story 1 end-to-end <15s p95; QR Story 2 end-to-end <25s p95; gossip reconnect-to-cursor <5s on healthy network; fingerprint render <50ms; card-presentation latency from QR-detect or long-poll-arrival to card visible <0.4s p95 (no intermediate loading indicator); confirm-to-dismiss perceived duration 0.6–1.0s with haptic + animation feedback; gossip-event-applied to UI-render cycle <16ms (one frame at 60Hz).
**Constraints**: No `HH_priv` exposure to the iPhone. No MachineCert signing on the iPhone. No bearer-token authorization. No polling for member updates. No macOS owner-confirmation. No new top-level screens. APNS payload contains zero household data. BIP39 wordlist version pinned cross-repo.
**Scale/Scope**: One iPhone, ≤4 pending join requests visible simultaneously (UX practical bound; not a hard limit), gossip event volume <10/min in normal household operation.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

| # | Principle | Status | Notes |
|---|-----------|--------|-------|
| I | Apple-Grade Quality (no SPOF, no manual ops, automatic discovery/failover, UX hides infrastructure from non-technical users) | PASS | Bonjour-shortcut and QR-fallback collapse to one UX. No host/IP/Tailscale-name input. Same fingerprint format both transports. APNS wakeup is opaque; Tailscale long-poll is the data path. Gossip-driven membership update — no manual refresh. |
| II | Capability-Based Authorization (signed certs chain to household root; no RBAC; no bearer for household ops; UI rendered from local cert) | PASS | Operator-authorization is a P-256 ECDSA over canonical CBOR by the owner PersonCert key, not a bearer. iPhone never signs MachineCert (that requires `HH_priv`, which iPhone never holds). Confirmation card is gated on local owner cert validity. |
| III | Local-First Identity & State (no central cloud control plane; Bonjour + Tailscale only) | PASS-WITH-VARIANCE | APNS-as-wakeup is a control-plane signal that traverses Apple infrastructure. Variance accepted by user 2026-05-06 (Q1 → C). Mitigations: (a) APNS payload contains zero household data (FR-004 + SC-010), (b) APNS sender is elected, not pinned, removing SPOF (FR-027 + SC-016), (c) user can disable APNS per-household and fall to pure local long-poll (FR-028 + SC-015). Removing APNS only costs background-wake latency, never correctness. See Complexity Tracking. |
| IV | Adoption-First, No Legacy Compatibility (no parallel old/new code paths; phase ends end-to-end functional) | PASS | The gossip consumer fully replaces the (never-present) polling baseline. The confirmation card extends the Phase 2 scanner via the same dispatcher; no legacy join path is left in place. |
| V | Specification-Driven Development (closed plan, no open alternatives; English artifacts; spec exists before implementation) | PASS | Spec is closed via 5 clarification answers + protocol-derived defaults. This plan picks concrete Apple APIs with no "TBD" choices. Cross-repo dependencies are explicit (FR-008 follows §5 canonicalization; SC-004 fuzz-binds the fingerprint). |

Engineering standards check:

- [x] Apple APIs used precisely: `Security.SecKeyCreateSignature` for owner authorization (already operable from Phase 2), `LocalAuthentication.LAContext` for biometric prompt with reason string, `URLSessionWebSocketTask` for gossip, `URLSession` long-poll for owner-events, `UNUserNotificationCenter` for APNS registration, `Network.NWBrowser` is *not* used here (Bonjour discovery is candidate-side; iPhone receives requests via push, not via direct mDNS browse).
- [x] Cryptographic primitives match Engineering Standards: EC P-256 ECDSA `r || s` with deterministic CBOR canonical form for the operator-authorization; BLAKE3-256 for fingerprint; CRL + issuer chain validation for gossip MachineCert events.
- [x] No silent error swallowing at protocol boundaries: gossip event validation errors are surfaced to a diagnostic store; URI rejection is human-readable; biometric cancel returns to pre-confirm state.
- [x] Tests planned at protocol boundaries: URI parser, fingerprint determinism, CBOR canonicalization, idempotency, gossip event validation under valid/invalid issuer/CRL, reconnect cursor behavior.

**Result**: Principles I, II, IV, V PASS. Principle III PASS-WITH-VARIANCE; entry recorded in Complexity Tracking.

## Cross-Repo Contracts (must agree with theyos Phase 3)

This feature has hard cross-repo bindings. Each must match theyos exactly:

1. **`JoinChallenge` (candidate-side signature input, FR-029)**: deterministic CBOR (RFC 8949 §4.2.1, lex-ordered keys) of `{v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}`. The candidate signs this with `M_priv` at install-time, producing `challenge_sig`. The iPhone reconstructs and verifies. Owner: theyos `docs/household-protocol.md` §11 + `specs/003-machine-join/contracts/`.
1a. **Owner-approval signature (FR-008)** — pinned 2026-05-06 cross-repo:
    - **Inner signed context** (`OwnerApprovalContext`): `{v=1, purpose="owner-approve-join", hh_id, p_id, cursor, challenge_sig, timestamp}`, deterministic CBOR (RFC 8949 §4.2.1, lex-ordered).
    - **Outer wire body** (`OwnerApproval`): `{v=1, cursor, approval_sig}` where `approval_sig` is 64-byte raw P-256 ECDSA `r||s` over canonical CBOR(OwnerApprovalContext).
    - **Decision** (approve/decline) is in the path, not the body — same outer-body shape on both routes.
    - Server-side validation (informational, theyos-owned): outer Soyeht-PoP timestamp ±60s; CBOR decode; `approval_sig` verifies under owner `p_pub`; `cursor` (path) == `cursor` (body) == `PairMachineWindow.owner_event_cursor`; `challenge_sig` (body) bit-equals `PairMachineWindow.cached_join_request.challenge_sig` (transitive binding cross-check); `p_id` matches owner cert; `hh_id` matches local; `timestamp` ±60s. Failure on any step → 401 generic CBOR.
2. **Fingerprint algorithm (FR-005, SC-004)**: `BLAKE3-256(M_pub_SEC1)` first 66 bits → 6 × 11-bit indices into the official BIP-0039 English wordlist. Single-locale cross-repo canon. Cross-repo binding test (SC-004) consumes `theyos/specs/003-machine-join/tests/fingerprint_vectors.json` byte-for-byte (16+ golden vectors).
3. **TTL (FR-012)**: 5 minutes, equal to QR/Bonjour `nonce` TTL in §11.
4. **APNS contract (FR-004, FR-023..FR-028)**: APNS payload contains zero household data and is byte-identical to `b'{"aps":{"content-available":1}}'`, the minimal Apple-required silent-push envelope. Push token registration is PoP-authenticated via `POST /api/v1/household/owner-device/push-token` and carries only `{v=1, platform="ios", push_token}` in the CBOR body; the owner `p_id` is bound by Soyeht-PoP. The household-side APNS sender role is filled by an elected machine (theyos protocol §13), not pinned to the founding Mac, so the iPhone still rings even if the Mac is asleep. The iPhone honors a per-household "Apple Push Service" toggle that, when off, suppresses registration and falls back to foreground-only long-poll (preserving a pure-local-first path for users who want strict Principle III adherence).
5. **Gossip event types (FR-014)**: `machine_added` and `machine_revoked` event shapes from §10. Filtering MAY be client-side (iPhone discards non-membership events) — theyos is not required to provide a filtered stream.
6. **Bonjour-shortcut → owner-event relay**: when Bonjour publishes the candidate, the receiving Mac packages the request into the owner-events queue that the iPhone long-polls. Cross-repo: theyos defines the long-poll endpoint shape (`GET /api/v1/household/owner-events?since=<cursor>`); this spec assumes its existence.
7. **`pair-machine` URI** (theyos `docs/household-protocol.md` §11, post-2026-05-06 amendment): `v=1`, `m_pub`, `nonce`, `hostname` (percent-encoded), `platform ∈ {macos, linux-nix, linux-other}`, `transport ∈ {lan, tailscale}`, `addr`, `challenge_sig` (base64url, 64 bytes), `ttl`. The QR is a self-contained credential — iPhone verifies `challenge_sig` locally before any network call.
7a. **Bonjour-shortcut transport (theyos-confirmed 2026-05-06)**: Bonjour TXT records carry only short discovery hints (`pairing=machine, pair_role=joiner, pair_nonce=<8-byte base32>, m_pub_b32=<truncated BLAKE3-128 base32>`) — never trust input, never `challenge_sig` (TXT 255-byte limit + TXT is unauthenticated by construction). On detecting the announcement, M1 fetches the full signed `JoinRequest` via `GET https://<addr>:<port>/pair-machine/local/seed?nonce=<short>` from M2's pre-household HTTPS listener, validates `challenge_sig` locally under `m_pub`, then stages the same ceremony as Story 2 from that point on. The iPhone sees the byte-identical `JoinRequest` CBOR via `OwnerEvent.payload.join_request_cbor` regardless of whether Story 1 or Story 2 produced it. iPhone has zero responsibility for the M1↔M2 seed fetch — that's pure theyos territory.
10. **Uniform CBOR wire format on Phase 3 endpoints (FR-030, FR-031)**: all request and response bodies, including 4xx/5xx error bodies, are deterministic CBOR per RFC 8949 §4.2.1 with `Content-Type: application/cbor`. Error body shape: `{v=1, error=<string>}`. No JSON anywhere on Phase 3 wire. iPhone HTTP client enforces this.
11. **APNS payload (FR-004, SC-010)**: literally bytes-identical `b'{"aps":{"content-available":1}}'`. No hint, no metadata beyond Apple's required silent-push `aps.content-available` envelope. iPhone never reads household content from the payload; arrival only schedules a Tailscale long-poll fetch.
8. **Household snapshot (FR-021, SC-011)**: `GET /api/v1/household/snapshot` returns a signed bundle including current members and CRL. Signature verifiable against `hh_pub`. Consumed once on first connection; subsequent state evolves via gossip.
9. **APNS push-token endpoint (FR-023..FR-026)**: `POST /api/v1/household/owner-device/push-token`, PoP-authenticated, body schema as defined in `contracts/apns-registration.md`. Current theyos Phase 3 does not define a deregistration route; session clear deletes local registration state and suppresses future registrations until a new household session is paired.

Items needing explicit cross-repo confirmation before implementation begins:
- Owner-events long-poll endpoint shape and authentication (PoP using Phase 2 owner cert).
- APNS-sender election protocol — theyos owns implementation; iPhone observes correct delivery and fails over invisibly.
- APNS sender election protocol and any future explicit deregistration / `unknown-token` surface beyond the current idempotent push-token registration endpoint.
- BIP39 wordlist pinned revision is verified byte-identical across repos; fixture expansion remains optional future hardening.
- Household snapshot signature scheme (which key signs — household root or member-cert chain).

## Project Structure

### Documentation (this feature)

```text
specs/003-machine-join/
├── plan.md
├── spec.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── pair-machine-url.md
│   ├── operator-authorization.md
│   ├── owner-events-long-poll.md
│   ├── household-gossip-consumer.md
│   ├── apns-registration.md
│   └── household-snapshot.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/SoyehtCore/
├── Sources/SoyehtCore/
│   ├── Household/
│   │   ├── PairMachineQR.swift                      # NEW — protocol §11 parser
│   │   ├── JoinRequestEnvelope.swift                # NEW — unified Bonjour/QR JoinRequest
│   │   ├── JoinRequestQueue.swift                   # NEW — TTL-bounded pending store, idempotent
│   │   ├── OperatorFingerprint.swift                # NEW — BLAKE3 → BIP39×6
│   │   ├── BIP39Wordlist.swift                      # NEW — pinned wordlist loader
│   │   ├── OperatorAuthorizationSigner.swift        # NEW — CBOR canonical + P-256 ECDSA via SE
│   │   ├── HouseholdGossipConsumer.swift            # NEW — WS consumer + cursor + validation
│   │   ├── MachineCertValidator.swift               # NEW — issuer chain + CRL
│   │   ├── CRLStore.swift                           # NEW — Keychain-backed observable CRL cache
│   │   ├── RevocationEntry.swift                    # NEW — codable revocation record
│   │   ├── HouseholdSnapshotBootstrapper.swift      # NEW — first-connection snapshot ingest
│   │   ├── HouseholdSession.swift                   # MODIFIED — gossip-driven, reactive member mutation
│   │   └── (existing Phase 2 files unchanged)
│   ├── Networking/
│   │   ├── OwnerEventsLongPoll.swift                # NEW — Tailscale long-poll client
│   │   ├── HouseholdGossipSocket.swift              # NEW — URLSessionWebSocketTask wrapper
│   │   └── (existing files unchanged)
│   ├── Resources/
│   │   └── Wordlists/
│   │       └── bip39-en.txt                         # NEW — official BIP-0039 English (single-locale cross-repo canon)
│   └── (other existing files unchanged)
├── Tests/SoyehtCoreTests/
│   ├── PairMachineQRTests.swift
│   ├── OperatorFingerprintTests.swift               # determinism + cross-repo fuzz fixture
│   ├── OperatorAuthorizationSignerTests.swift       # CBOR canonical + signature verification
│   ├── JoinRequestQueueTests.swift                  # TTL, idempotency, double-tap
│   ├── HouseholdGossipConsumerTests.swift           # cursor, dedupe, validation, CRL population
│   ├── MachineCertValidatorTests.swift              # issuer chain, CRL, hh_id mismatch
│   ├── CRLStoreTests.swift                          # NEW — persistence, dedupe, observability
│   ├── HouseholdSnapshotBootstrapperTests.swift     # NEW — signed snapshot ingest, CRL seed
│   └── HouseholdFixtures/
│       └── MachineJoin/
│           ├── fingerprint_vectors.json             # byte-identical theyos golden vectors
│           └── snapshot-fixtures/                   # signed snapshots for bootstrapper tests
└── Package.swift                                    # MODIFIED — add Resources/Wordlists copy

TerminalApp/Soyeht/
├── QRScannerView.swift                              # MODIFIED — add /pair-machine case
├── Household/
│   ├── HouseholdHomeView.swift                      # MODIFIED — host confirmation card sheet
│   ├── JoinRequestConfirmationView.swift            # NEW — single card UI for both transports
│   ├── JoinRequestConfirmationViewModel.swift       # NEW — biometric, idempotency, error states
│   ├── OwnerEventsCoordinator.swift                 # NEW — Hybrid push transport orchestration
│   ├── ApplicationDelegate+APNS.swift               # NEW or MODIFIED — opaque-tickle handler with empty-payload assertion
│   └── APNSRegistrationCoordinator.swift            # NEW — token register/refresh/local-clear/recovery lifecycle

TerminalApp/Soyeht/Settings/
├── SettingsRoute.swift                              # MODIFIED — add `.householdApplePushService` case
├── SettingsRootView.swift                           # MODIFIED — add "Apple Push Service" toggle row routing to the new case (no new top-level screen)
└── HouseholdApplePushServiceView.swift              # NEW — sub-route detail view with the on/off toggle, follows existing settings-row-detail pattern

TerminalApp/SoyehtTests/
├── JoinRequestConfirmationViewModelTests.swift
├── QRScannerViewMachineDispatchTests.swift
└── OwnerEventsCoordinatorTests.swift                # foreground long-poll vs. BG APNS arbitration
```

**Structure Decision**: All transport-agnostic logic (URI parser, fingerprint, signer, queue, gossip consumer, MachineCert validator) lives in `SoyehtCore` so it stays platform-agnostic and is reusable when macOS Soyeht eventually gains owner-confirmation parity. The iPhone-only confirmation surface and the Hybrid-push orchestration live in `TerminalApp/Soyeht/` because they bind to UIKit (`UIApplication`, `UNUserNotificationCenter`, AVFoundation camera, biometric prompt UX) which must not leak into core.

## Phase 0: Research

Output: `research.md`. Key items:

- BIP-39 wordlist: official BIP-0039 English (2048 words, ≈14KB), single-locale cross-repo canon. Vendor byte-identical to theyos's reference. SC-004 enforces byte-equal fingerprint output via shared golden-vector fixture (`theyos/specs/003-machine-join/tests/fingerprint_vectors.json`).
- `BLAKE3-256(M_pub_SEC1) → 66-bit truncation → 6 × 11-bit BIP39 indices`: confirm endianness and bit-extraction match the cross-repo reference implementation; lock with golden vectors.
- APNS background-wakeup latency on iOS 16/17/18 with `content-available: 1` silent push; BGAppRefresh budget interaction.
- `URLSessionWebSocketTask` resilience patterns: ping/pong cadence, reconnect with exponential backoff, cursor-resume on `1006`/`1011` close codes.
- Tailscale node IP discovery from the local snapshot (Phase 2 already stores `members[*].tailscale_addr`); confirm we don't need TSC SDK calls.
- Owner-events long-poll cursor semantics: monotonic event id with server-side gap-fill on reconnect.
- iOS-side Face ID failure surface: `LAError.userCancel` vs. `LAError.biometryLockout` vs. `LAError.userFallback` (we accept only biometric for this feature; password fallback is rejected per Constitution I).

## Phase 1: Design Artifacts

- `data-model.md`: full attribute schema for `JoinRequestEnvelope`, `OperatorFingerprint`, `OperatorAuthorization`, `JoinRequestQueue`, gossip event variants, `MachineCert` (mirrors §5 schema), CRL entry shape.
- `contracts/pair-machine-url.md`: parser grammar, error taxonomy, golden vectors.
- `contracts/operator-authorization.md`: deterministic CBOR canonicalization rules (key ordering, integer encoding, bytes encoding), signing input bytes, verification recipe.
- `contracts/owner-events-long-poll.md`: HTTP shape, headers, `since` cursor semantics, idle timeout, reconnect rules, fence with APNS-wakeup.
- `contracts/household-gossip-consumer.md`: WebSocket lifecycle, event envelope, accepted types in this phase, cursor persistence rules, MachineCert validation pipeline.
- `contracts/apns-registration.md`: current theyos push-token registration endpoint, APNS tickle byte invariant, rotation, foreground re-registration, and session-clear local behavior.
- `contracts/household-snapshot.md`: root-signed snapshot envelope, CRL schema, MachineCert validation order, and atomic bootstrap rules.
- `quickstart.md`: developer how-to from a fresh checkout — boot a dev household, enroll iPhone via Phase 2 quickstart, simulate a Bonjour-shortcut request, simulate a remote QR, exercise failure paths.

## Phase 2 onwards

`/speckit-tasks` produces `tasks.md` with dependency-ordered tasks; the user approves before any implementation. No code is written under this branch until the user approves the plan + tasks.

## Complexity Tracking

| Item | Variance from constitution | Why accepted | Cost if reverted |
|---|---|---|---|
| APNS-as-wakeup transport (Principle III) | Cloud services are not for control-plane functions; APNS-as-wakeup is a control-plane signal that traverses Apple infrastructure. | User chose Hybrid push (Q1 → C, 2026-05-06) explicitly to keep BG-wakeup latency at iOS-native levels. Variance is mitigated to the minimum: empty payload (FR-004 + SC-010, verified by APNS-payload-empty invariant test), elected sender (FR-027, no SPOF), user opt-out (FR-028 + SC-015, pure-local-first path preserved). | Foregrounded-only owner-events; users with iPhone in pocket >5min would not see Bonjour-shortcut requests until next app open. UX still works for Story 2 (QR scan is a foreground action by definition). |

## Self-Rating

**9/10** (post-hardening pass).

Justification:

- **+** Spec is closed end-to-end with no "TBD" alternatives; every FR has a concrete Apple-API or protocol citation.
- **+** Cross-repo contracts are enumerated explicitly with named protocol sections; cross-repo binding test (SC-004) catches drift mechanically.
- **+** Architecture forces the safe default (iPhone never holds `HH_priv`, never signs MachineCert) and that is reflected in FR-010 + the cryptographic-role preamble of the spec.
- **+** UX collapses both transports into one card per the canonical 12-story target (Stories 2 & 3); zero new top-level screens.
- **+** Idempotency, TTL, gossip resume, and APNS-payload-sanitization are explicit success criteria, not aspirations.
- **+** Hardening pass added CRL ingestion pipeline (FR-021/22 + SC-011/12 + CRLStore/Bootstrapper/RevocationEntry) — closes the SC-006 implementability gap.
- **+** Cross-repo alignment with theyos: QR carries `challenge_sig` so the iPhone verifies the candidate's identity locally before any network call (one-hop architecture; cryptographic anti-phishing). Multi-locale BIP-39 hardening rolled back in favor of theyos's English-only canon — single source of truth for the cross-repo binding fixture, no locale-mismatch class of bugs.
- **+** APNS lifecycle (FR-023..FR-028) is now self-healing: rotation, deregister, foreground-recovery — the iPhone owner ringing is auto-managed.
- **+** Constitution III variance is minimized to the smallest reasonable envelope: empty payload + elected sender + user opt-out, all measurable.
- **+** Confirmation card UX promoted to Apple Pay / AirDrop / Apple Music fluidity standards (haptics, spatial-continuity transition, multi-card stacking), now in acceptance scenarios and SCs.
- **−** The owner-events long-poll endpoint is *assumed* to exist on the theyos side. If theyos Phase 3 chooses a different transport (e.g., a member-side WebSocket that pushes owner-events as a typed channel of the gossip stream), FR-004 and the `OwnerEventsLongPoll.swift` boundary need replanning. Surfaced as an explicit cross-repo confirmation item; not closed in this plan.
- **−** APNS sender-election protocol §13 is theyos-owned and assumed; if it slips, FR-027/SC-016 stays gated until that contract lands.
- **−** Snapshot and gossip envelopes still need a final theyos-owned contract before production implementation. The local contracts pin the iPhone-required root-signed snapshot envelope and normalized gossip handling so implementation has a reviewable target, but cross-repo acceptance remains the gate.

The two minus items are both cross-repo coordination, not iSoyehtTerm-internal architecture. They are documented and gated, not deferred.
