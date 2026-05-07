# Feature Specification: Phase 3 - Machine Join (Soyeht iPhone)

**Feature Branch**: `003-machine-join`
**Created**: 2026-05-06
**Status**: Clarified + Hardened + Cross-repo aligned (theyos sync 2026-05-06)
**Input**: User description: Enable a second (and any subsequent) machine to join the already-bootstrapped Casa Caio household via a single iPhone-owner-confirmed ceremony. The same confirmation surface, fingerprint format, and biometric authorization apply whether the candidate machine is on the same LAN (Bonjour-discovered) or remote (QR-over-Tailscale). The owner authorizes; the founding Mac signs the resulting MachineCert with the household root key (Secure Enclave-resident on the founding Mac per protocol §6). Scope is the iSoyehtTerm client side only — covers Stories 2 (LAN) and 3 (remote) of the canonical 12-story UX target. Excludes Bonjour publication on the candidate, the join-listener on theyOS, Shamir splitting / re-sharding, server-side join acceptance, person invitations, revocation flows, Claw placement, and any macOS-side owner-confirmation surface.

**Backend Companion**: theyOS Phase 3 specs (in active development at `/Users/macstudio/Documents/theyos/specs/`). Cross-repo protocol contract: `/Users/macstudio/Documents/theyos/docs/household-protocol.md` — specifically §5 (Machine membership), §6 (Household private key custody), §10 (Event log & replication), §11 (URI / QR scheme), §12 (REST API), §13 (Network discovery).

**Cryptographic role of the iPhone in this feature** (per protocol §5/§6): the iPhone does **not** sign MachineCerts. The household root scalar `HH_priv` lives in the founding Mac's Secure Enclave (single-machine household at the start of this feature). The iPhone owner's role is to *operator-authorize* the join request by producing a P-256 ECDSA signature with the owner PersonCert key (`qr_signature` per §5 join endpoint) over a deterministic CBOR commitment to the join request. The Mac validates the owner authorization, performs the SE-handover-to-Shamir-split flow (Mac-side, out of scope here), signs `MachineCert.issued_by = hh_id` with `HH_priv`, and returns the cert to the candidate. The iPhone only ever sees the *result* (a new `MachineCert` event in the gossip stream).

## Clarifications

### Session 2026-05-06

- Q: How does the iPhone owner receive the join-confirmation prompt across both LAN and remote transports? → A: Hybrid — Tailscale long-poll while the app is foregrounded; APNS silent wakeup (opaque tickle, no payload data) only when backgrounded beyond an iOS-managed BGAppRefresh window, fetching the actual request payload over Tailscale on wake.
- Q: What anti-phishing fingerprint format is shown side-by-side on the candidate machine and the iPhone confirmation? → A: 6 BIP-39 English words derived from the first 66 bits of `BLAKE3-256(M_pub_SEC1)` (6 × 11-bit BIP-39 indices). Single-locale (English-only) cross-repo canon; words function as visual cryptographic-checksum tokens, not localized prose. Cross-repo binding fixture at `theyos/specs/003-machine-join/tests/fingerprint_vectors.json`. (Original clarification proposed multi-locale; rolled back during 2026-05-06 cross-repo alignment to match theyos's English-only canon — see "Cross-Repo Alignment Pass" section.)
- Q: What is the lifecycle when the owner-iPhone is unreachable while a join request is pending? → A: Hard 5-minute TTL aligned with the QR/Bonjour nonce TTL from protocol §11. No queue, no persistent pending list. The candidate shows a countdown; on TTL expiry the request is server-side invalidated and the candidate must regenerate its QR/Bonjour announcement to retry.
- Q: Does this feature cover macOS-side owner-confirmation as well as iOS? → A: iPhone-only owner-confirmation in this feature. `Packages/SoyehtCore/Household/` code remains platform-agnostic (no UIKit/AppKit imports in core). macOS Soyeht observes membership updates read-only via gossip but cannot itself authorize joins. macOS owner-device parity is deferred to a later feature.
- Q: How does the iPhone's local `HouseholdSession` learn about the new machine after the Mac issues the MachineCert? → A: A minimal household gossip WebSocket consumer (`GET (WS) /api/v1/household/gossip`, protocol §12) introduced in this feature, filtered to membership-event types (`machine_added`, `machine_revoked`) only. Forward-compatible with later phases that will add person/Claw event handlers to the same dispatcher.

### Hardening Pass 2026-05-06 (post-/speckit-analyze)

Following a cross-artifact analysis, five quality issues were identified and resolved by hardening the spec rather than narrowing scope (Apple-grade quality bar, Constitution Principle I): CRL ingestion pipeline made first-class with snapshot+delta semantics; APNS device-token lifecycle (registration, rotation, deregister, foreground-recovery) made fully automatic; Constitution Principle III variance hardened to minimum cost (elected APNS sender removes SPOF; per-household opt-out preserves a pure-local-first path); confirmation card UX promoted to Apple Pay / AirDrop / Apple Music fluidity standards (haptics, spatial-continuity transition, multi-card stacking).

### Cross-Repo Alignment Pass 2026-05-06 (theyos contract sync)

Backend (theyos) shipped four contract changes that strengthen the iPhone-side architecture; this spec is updated to consume them as the cross-repo source of truth:

1. **QR carries challenge_sig + hostname + platform**: The candidate's installer signs a `JoinChallenge` CBOR commitment with `M_priv` at install-time and embeds the resulting signature in the QR. The QR becomes a self-contained credential. The iPhone verifies `challenge_sig` under `M_pub` *before any network call* — invalid QR is rejected without contacting any household member. Hostname and platform are now cryptographically bound (any modification invalidates the signature). One network hop only: iPhone → M1 via Tailscale; the iPhone never connects to M2.
2. **JoinChallenge schema**: `{v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}` with deterministic CBOR per RFC 8949 §4.2.1 (lex-ordered keys). No `hh_id` (the candidate doesn't know the household at install-time; binding comes from nonce single-use + TTL + Tailscale destination).
3. **Uniform CBOR wire format on all Phase 3 endpoints**: Both success and error responses are deterministic CBOR. Error body shape is `{v=1, error=<string>}` with `Content-Type: application/cbor`. The iPhone's HTTP client parses 4xx/5xx as CBOR, never JSON, on any Phase 3 endpoint.
4. **APNS payload is literally `b'{"aps":{"content-available":1}}'`** — bytes-identical every time. No hint field, no household metadata, only the Apple-required silent-push envelope. The iPhone's silent-push handler never reads household content from the payload; it always performs a Tailscale long-poll fetch on wake. This preserves opacity while still waking iOS correctly.

The 10-locale BIP-39 hardening from the prior pass is **rolled back** in favor of backend's English-only single-wordlist canon. Justification: BIP-39 English wordlist is an industry-standard cryptographic anti-phishing primitive; the words function as visual checksum tokens (not localized prose), and matching them is unambiguous regardless of the operator's preferred reading language. The Linux installer also renders English. A single canonical wordlist eliminates the entire locale-mismatch class of bugs and aligns with backend's `tests/fingerprint_vectors.json` golden vectors.

## User Scenarios & Testing *(mandatory)*

The primary actor is the household owner (Caio) using the already-paired Soyeht iPhone (owner PersonCert minted in Phase 2). The supporting systems are (a) the founding Mac Studio of Casa Caio, holding `HH_priv` in its Secure Enclave, reachable on the household LAN and via the household's Tailnet; (b) a candidate machine that has just installed theyOS, generated its own EC P-256 keypair `(M_priv, M_pub)`, and is announcing readiness either via Bonjour `_soyeht-pair._tcp` (LAN) or via a `soyeht://household/pair-machine` QR (remote).

### User Story 1 - Same-LAN machine join via Bonjour shortcut (Priority: P1)

The candidate machine (e.g., the Linux Mini) is on the same Wi-Fi as Casa Caio. After theyOS install, the candidate publishes itself via Bonjour and submits a join-request to a reachable household member (the Mac). Within seconds, the iPhone surfaces a confirmation card showing the household name, the candidate's hostname and platform, and the 6-word BIP39 fingerprint derived from `M_pub_SEC1`. Caio compares the words on the iPhone with those displayed on the candidate's installer screen; they match. He taps Confirm, completes Face ID, and within seconds the candidate transitions to "joined". The iPhone's local `HouseholdSession.members` list grows by one — driven by the gossip stream, not by a refresh tap.

**Why this priority**: This is the canonical "second machine enters by itself" experience (Story 2 of the 12-story UX target). It is the fastest path to a multi-machine household and the daily-driver onboarding for any household that lives on a single Wi-Fi.

**Independent Test**: With the iPhone already paired (Phase 2 complete) and the founding Mac online, simulate a second-machine join request reaching the Mac with a known `(M_pub, hostname, platform, nonce)`; verify that the iPhone presents the confirmation card with the expected fingerprint, and that biometric confirmation results in a `machine_added` event for the same `m_id` arriving via the gossip consumer within the success-criteria latency budget, with no manual host entry, server selection, or login at any point.

**Acceptance Scenarios**:

1. **Given** the iPhone is paired to Casa Caio and the founding Mac is online and reachable, **When** a candidate on the same LAN submits a Bonjour-shortcut join request with a valid `(M_pub, nonce, hostname, platform)`, **Then** the iPhone displays the household name, candidate hostname, candidate platform, and the 6-word BIP39 fingerprint, deterministically derived from `M_pub_SEC1`.
2. **Given** the confirmation card is showing, **When** Caio taps Confirm and completes biometric authorization, **Then** the iPhone produces a P-256 ECDSA signature with the owner PersonCert key over a deterministic CBOR commitment to the join request and submits the operator-authorization to the Mac, then closes the card.
3. **Given** the Mac signs and returns the MachineCert and broadcasts a `machine_added` event, **When** the iPhone's gossip consumer receives the event for the matching `m_id`, **Then** the iPhone validates the cert against the locally-stored `hh_pub` and CRL, appends the new MachineCert to `HouseholdSession.members`, and the membership reflection completes without any user action and without any local polling.
4. **Given** Caio dismisses the confirmation card without confirming, **When** the request reaches its 5-minute TTL, **Then** the iPhone clears the pending entry locally, no operator-authorization is ever produced, and no MachineCert is issued.
5. **Given** the confirmation card is presented, **When** Caio taps Confirm, **Then** the device produces a light-impact haptic immediately on tap, a medium-impact haptic on biometric success, and the card transitions through a 0.6 s fingerprint-words → checkmark animation before auto-dismissing — matching Apple Wallet / Apple Pay confirmation feedback.
6. **Given** the gossip consumer applies the new `machine_added` event, **When** the household home view is visible, **Then** the new machine row enters with a brief highlight ring (subtle scale-in + accent-color border for 1.0 s) — matching Apple Music's "added to library" affordance — drawing attention without modal interruption.

---

### User Story 2 - Remote machine join via QR-over-Tailscale (Priority: P2)

The candidate machine is on a separate network from the household (cellular, office Wi-Fi, hotel) and is on the same Tailnet as Casa Caio. mDNS resolution does not produce the household. The candidate's installer renders a `soyeht://household/pair-machine` QR with `transport=tailscale` and an `addr=<tailscale-host:port>` of itself. Caio opens Soyeht on the iPhone, scans the QR with the same scanner that already accepts `pair-device` URIs, and the iPhone surfaces *the same confirmation card as Story 1*, with the same 6-word fingerprint format and the same biometric flow. Caio confirms; the operator-authorization travels via Tailscale to the Mac (on the household Tailnet), the Mac signs the MachineCert, the candidate receives it via the same Tailnet path, and the iPhone learns about the member via gossip — identical post-confirmation experience.

**Why this priority**: Story 3 of the 12-story UX target. Without a remote path, the household is geographically pinned to one LAN.

**Independent Test**: With the iPhone paired and on Tailnet, present a freshly-minted `soyeht://household/pair-machine` URI (validated against §11 fields: `v=1, m_pub, nonce, transport=tailscale, addr, ttl`); verify (a) scanning produces the same confirmation card UI as Story 1, (b) confirmation produces an operator-authorization signature, (c) the routing of that authorization uses the household's Tailnet and not LAN Bonjour, (d) the gossip-driven membership update arrives within the success-criteria latency budget.

**Acceptance Scenarios**:

1. **Given** the iPhone is paired to Casa Caio and on the household Tailnet, **When** Caio scans a valid `soyeht://household/pair-machine` URI, **Then** the iPhone presents the same confirmation card as Story 1, including the same 6-word BIP39 fingerprint computed identically over `M_pub_SEC1`.
2. **Given** the QR is for `transport=tailscale`, **When** the iPhone submits the operator-authorization, **Then** it routes to the household via Tailscale addresses from the local snapshot, not via Bonjour.
3. **Given** the QR is malformed, missing required fields per §11, of an unsupported version, or past its `ttl`, **When** the iPhone evaluates the URI, **Then** it rejects the URI with a recoverable, human-readable error and does not present the confirmation card.
4. **Given** the QR scanner detects a valid `pair-machine` URI, **When** the parser succeeds, **Then** the camera viewfinder transitions directly into the confirmation card (the card animates from the QR-frame rectangle outward), preserving spatial continuity — matching AirDrop's "incoming" presentation. No intermediate "loading" screen MUST be shown.

---

### User Story 3 - Reject and recover from join-request failures safely (Priority: P3)

The owner-iPhone may receive an inauthentic request, see a fingerprint that does not match the candidate's screen, lose connectivity mid-confirmation, scan an expired QR, or have its biometric attempt canceled. The app must explain the specific failure, never produce an operator-authorization signature on a request whose integrity it cannot vouch for, and never present a partial or speculative new member to the user.

**Why this priority**: Machine join is the moment a new long-lived attestation is being minted. Ambiguous failure paths either block multi-machine adoption or risk admitting a malicious machine.

**Independent Test**: Exercise: tampered request payloads (mismatched `M_pub` vs. fingerprint shown), wrong-household requests (request signed with the wrong `hh_id` claim), expired/replayed nonces, biometric cancel, network drop between confirmation tap and authorization delivery, malformed `pair-machine` URIs, and gossip events for `machine_added` whose MachineCert fails CRL/issuer validation. Verify that none of these paths add a member to `HouseholdSession.members`, none produce an operator-authorization signature, and none silently retry.

**Acceptance Scenarios**:

1. **Given** the recomputed fingerprint on the iPhone does not match the visible fingerprint on the candidate (operator says "no match"), **When** Caio dismisses the card, **Then** no operator-authorization is signed and the local pending entry is cleared.
2. **Given** the gossip stream delivers a `machine_added` event whose MachineCert fails issuer-chain or CRL validation, **When** the consumer evaluates it, **Then** the event is rejected, an integrity error is recorded for diagnostics, and `HouseholdSession.members` is not modified.
3. **Given** Caio cancels Face ID, **When** the system reports the cancel, **Then** the confirmation card returns to its pre-confirm state without producing any signature, and the request remains pending until TTL.
4. **Given** the network drops between the tap-Confirm and the operator-authorization being received by the Mac, **When** the iPhone reconnects within TTL, **Then** the iPhone re-submits the same operator-authorization (idempotent over the same nonce); when the iPhone reconnects after TTL, **Then** it discards the authorization without retry.

### Edge Cases

- The QR carries `version != 1` or unrecognized critical fields per protocol §11.
- The QR's `transport` is neither `lan` nor `tailscale`.
- The QR's `addr` is unreachable from the iPhone.
- Two different candidates submit join requests with different `M_pub` but the same `nonce` (collision or replay).
- The same join request is broadcast to the iPhone twice (push + Tailscale long-poll race) — must surface only one card and produce only one authorization.
- Two different iPhones owned by the same person somehow exist (future Story 10 territory; out-of-scope for confirmation, but the gossip consumer must tolerate any member changes regardless of who authorized them).
- Caio taps Confirm twice in rapid succession — must produce exactly one operator-authorization (idempotent locally).
- The candidate's hostname or platform string contains adversarial control characters or RTL overrides intended to obscure the displayed identity.
- The QR is missing `challenge_sig`, has malformed base64url, or `challenge_sig` fails P-256 ECDSA verification under `m_pub`; the iPhone MUST reject the QR locally and MUST NOT contact any household member.
- The QR's signed `JoinChallenge` reconstruction succeeds but the candidate's `m_pub` is itself malformed (not 33-byte SEC1 compressed P-256); reject locally before signature verify.
- A 4xx/5xx response on a Phase 3 endpoint arrives with `Content-Type: application/json` instead of `application/cbor`; the iPhone MUST treat this as a protocol violation, surface a typed error, and not attempt JSON parsing as a fallback.
- The local owner PersonCert is missing, expired, on the CRL, or for a different household than the request.
- The gossip WebSocket disconnects mid-session; reconnect must resume from the last applied event cursor without re-applying duplicates.
- The Mac is unreachable when Caio confirms (Mac asleep, Mac down) — confirmation produces a signed authorization that gets queued locally on iPhone for at-most-TTL retry; if TTL elapses without delivery, authorization is discarded.
- Caio confirms a join while a previous join is still pending in his card stack — each request has its own nonce; cards do not collapse.
- Multiple concurrent pending requests (rare but possible): the confirmation cards MUST stack in the iOS Notification Center pattern (most recent on top, older cards visible behind it as collapsed pills). Tap any pill to bring it forward. Each card carries its own TTL countdown.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST recognize `soyeht://household/pair-machine` URIs whose fields conform to protocol §11 (`v=1`, `m_pub`, `nonce`, `hostname` (percent-encoded), `platform ∈ {macos, linux-nix, linux-other}`, `transport ∈ {lan, tailscale}`, `addr`, `challenge_sig` (base64url, 64 bytes), `ttl`) and MUST reject malformed, expired, missing-field, or unsupported URIs before presenting the confirmation card.
- **FR-002**: The app MUST reuse the existing scanner in `TerminalApp/Soyeht/QRScannerView.swift`, extending its path dispatcher to cover both `/pair-device` (Phase 2, retained) and `/pair-machine` (this feature).
- **FR-003**: The app MUST receive Bonjour-shortcut join requests via the same in-app surface as remote-QR-initiated requests; both transports MUST converge to a single `JoinRequestConfirmation` UI component with identical fields.
- **FR-004**: The app MUST consume owner-targeted join-request events through the Hybrid push transport: a Tailscale long-poll endpoint while the app is foregrounded, and an APNS silent wakeup when backgrounded. The APNS payload MUST be exactly the bytes `b'{"aps":{"content-available":1}}'` — no hint field, no household-scoped metadata, only the Apple-required silent-push envelope. On wake the app MUST always perform a Tailscale long-poll fetch (no payload-driven shortcut to skip the fetch is permitted, since there is no hint field by design). The app MUST NOT read or branch on any APNS payload field beyond confirming the `aps.content-available = 1` wake shape itself occurred.
- **FR-005**: The app MUST deterministically render the operator fingerprint as 6 BIP-39 English words derived from the first 66 bits of `BLAKE3-256(M_pub_SEC1)` (6 × 11-bit BIP-39 indices). The wordlist is the official BIP-0039 English wordlist, single-locale, byte-identical to the version theyos uses (cross-repo binding fixture: `theyos/specs/003-machine-join/tests/fingerprint_vectors.json`). The same English words appear on both the candidate's installer and the iPhone confirmation card; the words function as a visual cryptographic-checksum token, not as localized prose, and matching is unambiguous regardless of the operator's preferred reading language.
- **FR-006**: The app MUST display the candidate's hostname and platform exactly as supplied by the join request, with no truncation in the trustworthy region of the card and with safe rendering for control characters and RTL overrides.
- **FR-007**: The app MUST require successful Secure Enclave biometric authorization (Face ID or Touch ID) before producing any operator-authorization signature.
- **FR-008**: The owner-approval flow uses an **inner signed context** (`OwnerApprovalContext`) and an **outer wire body** (`OwnerApproval`), both deterministic CBOR per RFC 8949 §4.2.1.

  Inner signed context (canonicalized; what the iPhone signs):
  ```
  OwnerApprovalContext = {
    v: 1,
    purpose: "owner-approve-join",
    hh_id: text,
    p_id: text,
    cursor: uint,                 // matches path param + PairMachineWindow.owner_event_cursor
    challenge_sig: bytes(64),     // candidate's challenge_sig — transitive binding to {m_pub, nonce, hostname, platform}
    timestamp: uint,              // unix-seconds; ±60s replay window
  }
  ```

  Outer wire body (what the iPhone POSTs):
  ```
  OwnerApproval = {
    v: 1,
    cursor: uint,
    approval_sig: bytes(64),      // raw r||s P-256 over canonical CBOR(OwnerApprovalContext)
  }
  ```

  The decision (approve vs decline) is conveyed by the path (`/owner-events/approve` vs `/owner-events/decline`), not by a body field; both paths use the same outer-body shape. The iPhone MUST sign `approval_sig` with the owner PersonCert key (Secure Enclave-backed, biometry-gated). Hostname/platform binding to the candidate is transitive via `challenge_sig` (verified by FR-029); reordering attacks are blocked by the triple-checked `cursor` (path × body × server-cached `PairMachineWindow.owner_event_cursor`); replay is blocked by `timestamp` (±60s server-clock tolerance, layered with the outer Soyeht-PoP timestamp). Source of truth: `theyos/specs/003-machine-join/contracts/owner-events.md`.
- **FR-009**: The app MUST NOT produce an operator-authorization signature for any request whose `hh_id` does not equal the locally stored household identifier.
- **FR-010**: The app MUST NOT issue, create, or sign any MachineCert; MachineCert issuance is performed exclusively by the founding Mac (or any machine holding sufficient Shamir shards) per protocol §5/§6.
- **FR-011**: The app MUST treat owner-authorization production as locally idempotent over `(hh_id, m_pub, nonce)`: tapping Confirm a second time on the same card MUST either return the previously-produced signature or no-op; biometric MUST be re-prompted only if the local cache for that nonce was cleared.
- **FR-012**: The app MUST enforce a hard 5-minute TTL on each pending request matching the QR/Bonjour nonce TTL of protocol §11; on TTL expiry the pending entry MUST be cleared without prompting and any locally-queued authorization for that nonce MUST be discarded.
- **FR-013**: The app MUST establish a household gossip WebSocket against any reachable household member at `GET (WS) /api/v1/household/gossip` (protocol §12), authenticated by Soyeht proof-of-possession (Phase 2 mechanism via `HouseholdPoPSigner`).
- **FR-014**: The gossip consumer MUST process `machine_added` and `machine_revoked` event types (and only those types in this phase), and MUST validate each MachineCert against the locally stored `hh_pub`, the protocol §10 issuer-chain rules, and the locally-cached CRL before mutating `HouseholdSession.members`.
- **FR-015**: The gossip consumer MUST be resilient to disconnects: reconnect MUST resume from the last applied event cursor, and duplicate events MUST be detected and not re-applied.
- **FR-016**: The app MUST NOT poll any endpoint to discover new household members. The gossip stream is the sole reactive source.
- **FR-017**: The app MUST present the confirmation card without revealing or requesting any of the following: server hostname, IP address, Tailscale machine name, household password, or bearer token. All routing data is sourced from the stored household record or from the scanned QR.
- **FR-018**: The app MUST surface a recoverable error path for: malformed/expired QR, mismatched `hh_id`, mismatched `m_pub` between request and a re-fetch attempt within TTL, biometric cancel, network drop, unreachable Mac, and gossip-event validation failure. Each path MUST be human-readable and MUST NOT silently retry.
- **FR-019**: The app MUST NOT introduce any new top-level screens for this feature beyond the confirmation card; the card surfaces over the existing household home view.
- **FR-020**: This feature MUST exclude: candidate-side Bonjour publication, theyOS join-listener, Shamir splitting and re-sharding, person invitations, revocation initiation, Claw placement, candidate-side QR rendering, and any macOS-side owner-confirmation surface.
- **FR-021**: The app MUST maintain a local Certificate Revocation List (CRL) cache populated from two sources: (a) the `crl` field of the household snapshot fetched on first connection (`GET /api/v1/household/snapshot`, protocol §12), and (b) every validated `machine_revoked` event observed in the gossip stream thereafter. CRL entries MUST persist to Keychain (encrypted at rest) and survive app launches.
- **FR-022**: When a `machine_revoked` event is applied, `HouseholdSession.members` MUST publish the change reactively to all subscribed view models within one render cycle; no app restart, manual refresh, or screen reopen MUST be required for the revoked machine to disappear from any list rendered from the session.
- **FR-023**: The app MUST register its APNS device token with the household via a PoP-authenticated `POST /api/v1/household/owner-device/push-token` call (sender chosen by the household leader-election protocol §13; iPhone selects via snapshot.members ranking). The CBOR body MUST include only `{v=1, platform="ios", push_token}`. It MUST NOT include `hh_id`, hostname, IP, or any household-scoped data; the household identifies the owner from the Soyeht-PoP-signed `p_id`.
- **FR-024**: The app MUST refresh its registration when iOS rotates the APNS token (`UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`) and the new token differs from the locally cached one. Identical-token re-registrations MUST be skipped to avoid wasted network calls.
- **FR-025**: When `HouseholdSession` is cleared (logout, household-leave, or session-corruption recovery), the app MUST delete local cached push-token registration state, stop the owner-events coordinator, and suppress future push-token registration until a new household session is paired. Current theyos Phase 3 does not define a network deregistration route; if one is added later, the local contract MUST be updated before implementing a best-effort network deregister.
- **FR-026**: On every app foreground, if local registration state is missing/stale or a future household response reports an unknown device token for `p_id`, the iPhone MUST re-register automatically through `POST /api/v1/household/owner-device/push-token`. This recovers from app reinstall, restore-from-backup, or APNS-token-rotation-while-offline without user action.
- **FR-027**: The iPhone MUST tolerate APNS sender failover transparently. It MUST accept any silent-push wakeup whose `apns-topic` matches the app bundle and whose `aps.content-available = 1`, regardless of which household machine sent it. It MUST NOT pin trust, retry behavior, or routing decisions to a specific sender machine identity, since the household-side sender role is filled by any reachable household machine via the leader-election protocol §13 (theyos-owned). The iPhone's only sender-side correctness check is the empty-payload invariant of FR-004 + SC-010. (Cross-repo dependency: theyos owns the election; this FR is the iPhone-side obligation that consumes it.)
- **FR-028**: The iPhone MUST expose a per-household setting "Apple Push Service" (default ON) that, when disabled, suppresses APNS registration and falls the iPhone back to foreground-only Tailscale long-poll for owner-events. The setting MUST be reachable from the household home view in two taps and MUST be added as a row to the existing household-settings surface (no new top-level screen, preserving FR-019).
- **FR-029**: The iPhone MUST verify the candidate's install-time `challenge_sig` for every join request, regardless of transport, before presenting the confirmation card. The verification reconstructs deterministic CBOR (RFC 8949 §4.2.1, lex-ordered keys) `JoinChallenge = {v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}` from the request's signed fields and verifies `challenge_sig` (P-256 ECDSA `r || s`, 64 bytes) under `m_pub`. Verification failure MUST cause the request to be rejected with a recoverable, human-readable error and MUST NOT result in any further contact with household members for that request. Successful verification establishes the cryptographic binding of `(m_pub, nonce, hostname, platform)`.

  Path-conditional sourcing of the signed fields:
  - **Story 2 (QR)**: fields come from URL query parameters of the scanned `pair-machine` URI; verification runs BEFORE any network call.
  - **Story 1 (Bonjour-shortcut)**: fields come from decoding `OwnerEvent.payload.join_request_cbor` (opaque CBOR bytes received via owner-events long-poll); verification runs immediately after decode, before card presentation.

- **FR-029a**: For Story 1 (Bonjour-shortcut path), after a successful FR-029 verification the iPhone MUST also re-derive the operator fingerprint locally from the decoded `m_pub` and bit-equal-check it against `OwnerEvent.payload.fingerprint`. Mismatch indicates derivation drift between server and client and MUST surface as a typed `MachineJoinError.derivationDrift`, blocking card presentation. (Story 2 has no analogous server-derived fingerprint to cross-check; the iPhone derives locally and that is the canonical value.)
- **FR-030**: On all Phase 3 endpoints (join-request, owner-events long-poll, owner-events approve, owner-events decline, push-token-register, machine-local seed/finalize), the iPhone MUST parse 4xx and 5xx response bodies as deterministic CBOR `{v=1, error=<string>}` with `Content-Type: application/cbor`. JSON error parsing on these endpoints MUST NOT be supported. Each typed `error` value MUST map to a case in `MachineJoinError` for human-readable surfacing per FR-018.
- **FR-031**: On all Phase 3 endpoints, the iPhone MUST send and receive request/response bodies as deterministic CBOR per RFC 8949 §4.2.1 (`Content-Type: application/cbor`). No mixed-format wire (e.g., JSON-success + CBOR-error or vice versa) is permitted; the wire-format invariant prevents content-type-confusion oracles and aligns with the cross-repo lint that theyos enforces structurally.

### Key Entities

- **PairMachineQR**: A scanned `soyeht://household/pair-machine` URI. Attributes: `v`, `m_pub`, `nonce`, `hostname`, `platform ∈ {macos, linux-nix, linux-other}`, `transport ∈ {lan, tailscale}`, `addr`, `challenge_sig: [UInt8 × 64]`, `ttl`.
- **JoinChallenge**: The deterministic CBOR commitment the candidate signs at install-time with `M_priv`. Schema: `{v=1, purpose="machine-join-request", m_pub, nonce, hostname, platform}` (RFC 8949 §4.2.1, lex-ordered keys). Reconstructed by the iPhone from `PairMachineQR` fields to verify `challenge_sig` under `m_pub` per FR-029. Never persisted; reconstructed on demand.
- **JoinRequestEnvelope**: The unified **in-memory iPhone type** holding a verified join request. Attributes: `hh_id`, `m_pub`, `nonce`, `hostname`, `platform`, `candidate_addr`, `ttl_unix`, `challenge_sig: [UInt8 × 64]`, `received_at`, `transport_origin ∈ {bonjour-shortcut, qr-tailscale, qr-lan}`. The wire encoding differs by transport: Story 2 builds the envelope from `pair-machine` URL query params; Story 1 builds it by decoding `OwnerEvent.payload.join_request_cbor` (opaque CBOR bytes from M1). At wire layer, `challenge_sig` is **inside** the CBOR blob in Story 1, never a top-level OwnerEvent field. Both paths converge to the same FR-029 verification.
- **OwnerEvent**: A single event in the owner-events long-poll stream. Attributes: `cursor: uint`, `type: text`, `payload: map`. For `type = "join-request"`, `payload = {join_request_cbor: bytes, fingerprint: text, expiry: uint}` per `theyos/specs/003-machine-join/contracts/owner-events.md`. The iPhone decodes `join_request_cbor` into `JoinRequestEnvelope`, runs FR-029 verification, runs FR-029a fingerprint cross-check, then enqueues into `JoinRequestQueue`.
- **OwnerApprovalContext**: The deterministic CBOR commitment the iPhone signs to authorize a join. Attributes: `v=1, purpose="owner-approve-join", hh_id, p_id, cursor, challenge_sig, timestamp` (lex-ordered). Never persisted; reconstructed and signed in-place per FR-008.
- **OwnerApproval**: The wire body the iPhone POSTs to `/owner-events/approve` (or `/decline`). Attributes: `v=1, cursor, approval_sig: [UInt8 × 64]`. Outer envelope; the inner `OwnerApprovalContext` is reconstructed by the server and verified using the public `p_pub` from the owner's PersonCert.
- **OperatorFingerprint**: The deterministic 66-bit BIP-39 English rendering of `BLAKE3-256(M_pub_SEC1)`. Attributes: `words: [String × 6]`, `digest_full: [UInt8 × 32]` (kept for diagnostic comparison only, never displayed in primary UI).
- **OperatorAuthorization**: The signed authorization Caio produces on confirmation. Attributes: `hh_id`, `m_pub`, `nonce`, `signature: [UInt8 × 64]` (P-256 ECDSA `r || s`), `signed_at`, `purpose: "machine-join-authorize"`. Idempotency key: `(hh_id, m_pub, nonce)`.
- **JoinRequestQueue**: The on-device pending-request store. At-most one entry per nonce; entries TTL out at 5 minutes; entries are cleared on confirmation, on TTL, or on observation of the matching `machine_added` event in the gossip stream. Concurrent pending entries surface as a stacked card UI in the home view.
- **HouseholdGossipConsumer**: The WebSocket-backed event ingester. Attributes: `cursor`, `connection_state`, `accepted_event_types ⊇ {machine_added, machine_revoked}`.
- **HouseholdSession.members**: The local membership view, mutated only by validated gossip events. Publishes changes reactively (`@Published`/`AsyncStream`) for one-render-cycle UI propagation.
- **CRLStore**: The local Certificate Revocation List cache. Attributes: `entries: Set<RevocationEntry>`, `snapshot_cursor`, `last_updated`. Mutated only by validated `machine_revoked` gossip events plus the boot-time household-snapshot. Persists to Keychain (encrypted at rest). Observable.
- **RevocationEntry**: A single revoked subject. Attributes: `subject_id (m_id | p_id | d_id)`, `revoked_at`, `reason`, `cascade ∈ {self_only, machine_and_dependents}`, `signature` (proof from the issuing cert).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With Mac, Linux candidate, and iPhone all online and on the same Wi-Fi, end-to-end Story 1 (Bonjour shortcut → confirmation → MachineCert visible in `HouseholdSession.members`) completes in under 15 seconds, measured 100 times in a fault-injection harness.
- **SC-002**: With Mac and iPhone on Tailnet and a remote candidate not on the LAN, end-to-end Story 2 (`pair-machine` QR scan → confirmation → MachineCert visible) completes in under 25 seconds, measured 100 times.
- **SC-003**: 100% of malformed, expired, wrong-version, wrong-household, and unsupported-transport `pair-machine` URIs are rejected before the confirmation card is presented.
- **SC-004**: The fingerprint computed by the iPhone matches the fingerprint computed by theyos's reference implementation of `BLAKE3-256(M_pub_SEC1) → BIP-39 English × 6` byte-for-byte across 100% of the golden vectors in `theyos/specs/003-machine-join/tests/fingerprint_vectors.json` (16+ vectors; cross-repo binding test runs the same fixture in both repos).
- **SC-005**: 100% of biometric-cancel paths produce no operator-authorization signature.
- **SC-006**: 100% of gossip events whose `MachineCert.issued_by != hh_id`, whose signature fails verification under `hh_pub`, or whose `m_id` is in the local CRL are rejected without mutating `HouseholdSession.members`.
- **SC-007a**: After a forced gossip-WebSocket disconnect during a 100-event replay, 0 events are re-applied (no duplicate insertions in `HouseholdSession.members`).
- **SC-007b**: After a forced gossip-WebSocket disconnect, reconnect reaches the latest cursor within 5 seconds on a healthy network.
- **SC-008**: Tapping Confirm twice in rapid succession produces exactly 1 operator-authorization signature (idempotency).
- **SC-009**: 0 polling requests to any household-member endpoint occur in normal post-pairing operation; verified via an `URLProtocol` recording fixture asserting outbound traffic is exclusively long-poll, gossip WS, and PoP-signed RPCs.
- **SC-010**: 0 APNS payloads observed by the iPhone contain household-scoped data; APNS is used as wakeup only (verified via an APNS-payload-empty-invariant test in the test environment).
- **SC-011**: A fresh app install joining a 30-day-old household completes its boot snapshot and rejects any presented MachineCert that is in the snapshot CRL with 100% accuracy on the next gossip-validated cert evaluation.
- **SC-012**: After a `machine_revoked` event for member `m_X` is applied, every view rendered from `HouseholdSession.members` reflects the removal within one SwiftUI render cycle (measured in UI tests).
- **SC-013**: After APNS token rotation, the iPhone re-registers automatically within 5 seconds of the next app foreground; the next outbound APNS wakeup from the household reaches the device with 100% delivery in test conditions.
- **SC-014**: After session clear, no APNS wakeups for the cleared session reach the device in subsequent test traffic (deregistration verified end-to-end).
- **SC-015**: With APNS disabled in the per-household setting, every join request still surfaces on the iPhone within 2 seconds of foregrounding the app; APNS-disabled mode passes the entire Story 1 + Story 2 acceptance suite (with foreground-app preconditions).
- **SC-016**: With the founding Mac powered down, a Story 1 join request still completes within the SC-001 budget via the elected backup APNS sender (cross-repo: theyos owns the election; iPhone observes correct delivery).
- **SC-017**: User-perceived latency from QR-detection or long-poll-arrival to confirmation-card-presented is under 0.4 s p95 on iPhone 12 and newer (no intermediate loading indicator).
- **SC-018**: User-perceived latency from biometric success to card auto-dismiss is between 0.6 s and 1.0 s (felt-instant but with enough time for the success animation to be perceived).

## Assumptions

- Phase 2 is complete: the iPhone holds a valid owner PersonCert for Casa Caio in Keychain, the Secure Enclave-backed owner identity is operable, and the iPhone holds the verified `hh_pub`.
- The founding Mac is online and reachable for the duration of any join attempt; the Mac-side SE-handover-to-Shamir-split flow exists in theyOS Phase 3 and is out-of-scope for this feature.
- The household's Tailnet is established for any remote-transport scenarios (Story 2). On-device Tailnet management is owned by the user/Tailscale.app, not this feature.
- The iPhone bundles the official BIP-0039 English wordlist (2048 words, ≈14 KB), vendored byte-identical to the version theyos ships in its reference fingerprint implementation.
- APNS push tokens are managed by theyOS (the elected household sender machine acts as APNS sender per FR-027); this feature only consumes opaque wakeups and submits PoP-signed token registrations.
- The protocol contract for `qr_signature` (FR-008) is fixed in §5 of `household-protocol.md`; if the canonicalization or field set changes cross-repo, this spec follows.
- The household-snapshot endpoint (`GET /api/v1/household/snapshot`) returns a signed bundle including the current CRL; theyos is responsible for that signature; this feature consumes and verifies it.
- The broader 12-story UX target contains additional flows (person invitations, Claw creation, machine revocation initiation, capability rotation, multi-device per person, offline browsing) that are not implemented here.
