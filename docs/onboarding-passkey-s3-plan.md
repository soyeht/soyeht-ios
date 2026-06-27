# Onboarding Passkey (Owner-Auth) — S3 iOS/macOS Plan & Status

_Status as of 2026-06-27. Owner of the Swift/SoyehtCore slice: @gianna.
Sequence coordination: @code-reviewer. iOS review: @julia. Backend: theyos._

This is the durable record of the S3 (iOS/macOS passkey **enrollment + approval**)
plan. It supersedes the ad-hoc status that lived only in agent memory. Everything
shipped so far is **inert / default-off** — no enforcement flip.

---

## 1. Mental model (read this first)

There are **two distinct owner credentials** — do not conflate them:

- **Owner identity key** — SE-resident P-256, created at pairing/bootstrap. Signs
  the **v1** owner approval + the `Soyeht-PoP` header. **Works today.**
- **Owner passkey** — WebAuthn, the new thing. Enrolled via the S3 client; will
  sign **v2** approvals (passkey assertion).

The v1 join-approval flow already works. The **v2 (passkey) path is additive and
INERT** until the enforcement flip (out of scope here). The UI must keep working
in v1 and be v2-ready.

**WYSIWYS binding is server-side.** The approval-v2 WebAuthn challenge is the
server's *random* nonce (`webauthn-rs`), **not** a digest of the context. The
operation↔approval binding is enforced server-side
(`challenge_id → context_binding → require_context`). ⇒ the client forwards the
challenge **opaque** and echoes the server `context` **exactly**; there is **no**
client-side `challenge == digest` guard (that premise was wrong and would reject
every approval — verified in Rust). The UI shows the trusted `context` before the
gesture (UI-layer WYSIWYS).

---

## 2. Status snapshot

| Layer | Done | Notes |
|---|---|---|
| **Backend (theyos)** | ~95% | S0/S1/S2/S3a merged, default-off. Status/E1 is merged. Revoke R1/R2/R3 are merged. Recovery R0 provision/readiness, R1-A consume model, R1-B0 cross-log consumed helpers + combined consumable-head helper, and backup/AddCredential contract/vectors are merged; consume/add runtimes and flip gates remain. |
| **Client (soyeht-ios)** | ~88% | **Headless chain 100% merged**. iOS enrollment screen and approval review screen are merged. macOS UDS/no-PoP client foundation is merged; macOS engine/app enrollment work remains. |
| **Rollout / active-for-user** | **0%** | Inert by design; gated on pre-flip gates + the flip. |

---

## 3. Backend (theyos) — merged, default-off

- **S0/S1/S2/S3a** merged. S2 = server-side challenge binding + anti-rollback
  authority anchor + pair-machine-approve handler wiring. S3a = owner passkey
  enrollment backend (genesis TOFU).
- **Pre-flip gates** (apply before flipping enforcement): double-prepare ✅,
  sign_count policy ✅, PolicySnapshot/trust-state ✅, dedicated enrollment op
  `OwnerAuthEnrollInitial` ✅, status/E1 marker-backed endpoint ✅. Revoke
  R1 contract/vectors ✅, R2 start/challenge ✅, and R3 finish mutation ✅.
  Recovery R0 provision/readiness ✅, R1-A consume model ✅, R1-B0 cross-log
  consumed helpers + combined consumable-head helper ✅, and
  backup/AddCredential contract/vectors ✅.
  **Remaining:** recovery consume/no-brick runtime, backup/AddCredential runtime,
  macOS local engine enrollment route, and the flip.
- **Golden vectors** (Rust↔Swift): #166 registration, #167 adapter contract,
  #170 approval-v2 wire, #174 revoke-credential context, #178 recovery
  provision context, and #179 AddCredential context.

---

## 4. Client (soyeht-ios) — headless chain COMPLETE (merged)

All in `Packages/SoyehtCore` (SPM, unit-tested, inert).

**Enrollment**
- #215 — registration DTOs (parity)
- #216 — `PasskeyProvider` registration ceremony
- #217 — in-flight cancellation
- #218 — `OwnerPasskeyEnrollmentClient` (HTTP/CBOR/PoP)
- #220 — `PasskeyProvider.authenticate` (assertion ceremony; unified `runCeremony<T>`)
- #229 — `OwnerPasskeyEnrollmentOrchestrator` (headless coordinator)
- #231 — `OwnerPasskeyRegistrationStatusClient` (E1 status read)
- #232 — `OwnerPasskeyEnrollmentViewModel` (headless state machine)
- #242 — macOS local-socket registration/status client foundation
  (HTTP-over-UDS transport + no-PoP local caller-auth mode, inert until engine
  routes exist)

**Approval-v2**
- #219 — `OwnerApprovalContextV2` DTO + challenge-digest
- #222 — wire DTOs: `OwnerApprovalV2`/`OwnerApprovalV2Finish` encoders +
  `OwnerApprovalV2StartResponse` decoder
- #223 — `OwnerApprovalV2Client` (`start` / `approveV2`)
- #224 — `OwnerApprovalV2Orchestrator` (headless coordinator)
- #228 — 2-phase `OwnerApprovalV2Orchestrator.prepare` / `confirm` split for
  review-before-gesture UI
- #235 — `OwnerApprovalV2ReviewViewModel` (pair-machine-approve review state
  machine; exposes context before confirm)
- #238 — iOS approval review screen + app-wrapper adapter (default-off v2 path,
  v1 fallback preserved)

**Fase-2 config (parallel track, orthogonal)**
- #221 — `OnboardingConfig` timeout SSOT (inert)
- #225 — first caller migration (`HouseholdPairingService`)
- #226 — `HouseNamingFromiPhoneView` slow-hint migration
- #230 — `AwaitingMacView` timeout migrations

---

## 5. Key invariants & decisions (do not regress)

- **Canonical CBOR** via `HouseholdCBOR`; **vector-parity Rust↔Swift is the merge gate.**
- **Wire field maps:**
  - Registration DTOs: base64url **TEXT** even in CBOR — except `FinishResponse.credential_id` (real byte-string).
  - Approval-v2 envelope (`OwnerApprovalV2`/`Finish`): assertion fields
    (`credential_id`/`authenticator_data`/`client_data_json`/`signature`/`user_handle`)
    are CBOR **byte-strings** (the *opposite* of registration). `user_handle`
    omitted-when-absent (never null).
  - StartResponse `options.publicKey.challenge` + `allowCredentials[].id` are
    base64url **TEXT** → decode to `Data` at the edge. `allowCredentials`
    "no restriction" collapses to `[]` (absent / null / empty array).
- **No client `challenge == digest` guard** (binding is server-side; challenge is random).
- **Anti-oracle:** any reject → generic `BootstrapError` (`serverError(code:"unauthenticated", message:nil)`),
  **never branch on `BootstrapError.code`**. UI rule: branch only on a successful
  status HTTP `200`; status `401` stays generic.
- **PoP** fresh-per-request, bound to `method + pathAndQuery + body`.

---

## 6. Remaining — UI / app-target

**6a. Enrollment screen: "Protect your home"**
- iOS: **merged**. `enrollOwnerPasskey(snapshot)` now sits between
  `pairingSuccess(snapshot)` and the recovery/household continuation in the
  post-owner setup flow.
- macOS: still gated, but the identity/caller-auth architecture is decided and
  the SoyehtCore UDS client foundation is merged. It is not a direct iOS port:
  the app target must not receive owner identity / PoP signer material. The
  engine keeps owner identity engine-side, exposes a local Unix domain socket to
  the signed Soyeht app, verifies the peer code signature (audit token ->
  SecCode -> designated requirement: apple-generic + team-id + bundle-id, not a
  raw cdhash pin), and treats WebAuthn attestation as the material grant only
  when it is constrained to user verification + platform authenticator +
  owner-exists / NeverEnrolled / default-off gates. TCP loopback or localhost +
  attestation alone is not authorization. The client foundation uses
  HTTP-over-UDS so existing CBOR DTOs/vectors can be reused; the security-critical
  engine route with peer code-signing + constrained attestation is still pending.
- The view is thin: switch only on `OwnerPasskeyEnrollmentViewModel.phase`.
  `.completed(.fresh)` and `.completed(.alreadyCommitted)` are success;
  `.failed(canRetry:)` shows one generic retry surface; `setUpLater()` is
  first-class and performs no network.
- The view must never inspect `BootstrapError`, `.code`, or raw errors. It only
  consumes the VM phase. Retry is manual; there is no automatic re-enroll.

**6b. Approval review VM** (SPM slice before the app-target screen):
- **Merged** as #235, pair-machine-approve only.
- First cut is pair-machine-approve only. The `cursor` comes from the
  owner-events long-poll / join-request queue and is the cursor used by
  `/owner-events/{cursor}/approval-v2/start` and `/approve`.
- `OwnerApprovalV2ReviewViewModel` wraps the merged 2-phase
  `OwnerApprovalV2Orchestrator`: `prepare(cursor:)` fetches the `startResponse`
  and exposes `startResponse.context`; `confirm(_:)` performs the gesture and
  posts the exact-context envelope.
- The VM owns phases such as `idle`, `prepared(context)`, `confirming`,
  `completed`, and `failed(canRetry:)`. It never exposes or interprets the
  opaque WebAuthn challenge, and it never branches on `BootstrapError.code`.

**6c. Approval review screen**
- iOS: **merged** as #238, still default-off. The v2 card is additive and gated;
  `JoinRequestConfirmationView` / v1 approval remain the default path.
- Renders the pair-machine context fields (op, machine id, addr, transport) before
  the owner can tap Approve. `confirm` is reachable only after explicit owner
  approval; it is never triggered automatically after `prepare`.
- The app-wrapper preserves the existing join-request lifecycle and B7 external
  anchor gate: `beginConfirming` -> `queue.claim` -> local anchor pin
  (`anchorSecret -> hh_id/hh_pub`) -> `confirm(prepared)` -> `confirmClaim`.
  The pin must complete before `confirm`, because approval-v2 immediately drives
  the engine-side finalize. The v2 path does **not** call the v1
  `approve(authorization)` wire path.
- Source guards prove the view renders context before confirm, pin happens before
  confirm, confirm only happens from the explicit Approve action, the v1 fallback
  remains default, and the view/adapter do not reference `BootstrapError`,
  `.code`, raw errors, or the WebAuthn challenge.
- Failures are terminal and generic at this layer. Anti-oracle covers observable
  behavior, not only error values, so retry availability must not reveal whether
  the failure happened during claim, pin, or confirm. A future retryable path must
  use a stage-agnostic queue/VM reason.
- No backup/subsequent path or non-pair-machine operation is exposed here.

**Test boundary:** SPM already covers the enrollment ViewModel, orchestrators,
clients, CBOR wire, status/E1, anti-oracle state transitions, and the approval
review VM. SwiftUI views, live
`ASAuthorization`, app navigation, and source guards are app-target / **CI-only**
because of the xcframework caveat; no local live ceremony is required.

---

## 7. Gated / pre-flip (NOT in scope yet)

- **recovery-code** — Caio: 1 passkey + 1 recovery at setup; pre-flip **blocker**.
  R0 provision/readiness is merged as default-off infrastructure, with
  shown-once recovery code semantics protected by the anchored/delivered/ready
  invariant. R1-A consume model and R1-B0 cross-log consumed helpers + combined
  consumable-head helper are merged as inert model infrastructure;
  consume/add-fresh-credential runtime is not implemented yet. This remains the
  **next runtime pre-flip priority** because recovery
  closes the "one passkey lost = permanent brick" story before any enforcement
  flip.
  - Recovery is a separate factor/anchor, **not** a WebAuthn credential. It must
    not be counted in `active_count`; `active_count` remains WebAuthn-only.
  - Normal `RevokeCredential` remains hard-blocked by `active_count <= 1`.
    Any future "last revoke with recovery" must be a separate explicit
    operation/policy that verifies a recovery anchor under the same lock. Do not
    silently relax the existing revoke path.
  - R1-B0 merged the SSOT consumed helpers on both sides of the future
    two-anchor runtime: recovery log `Consume(X)` and WebAuthn log Add actor
    `RecoveryProof(X)`, both sequence+hash bound. The combined helper now exposes
    the single "consumed by any log" predicate plus a consumable-head finder that
    returns only an active recovery verifier head not consumed by either log. The
    future runtime must call those predicates only after both relevant
    authorities have been verified and anchor-classified; they are not log
    validators.
  - R1-B runtime eligibility is a deliberate break-glass decision: WebAuthn
    authority must be ever-enrolled with a valid/repairable anchor/prefix, and
    `active_count` is telemetry rather than permission. The recovery head is
    consumed if either the recovery log has `Consume(X)` or the WebAuthn log has
    an Add actor `RecoveryProof(X)`; repair must run before any new-Add gate.
    The Add is audit-visible; owner notification is a follow-up mitigation.
- **backup / 2nd passkey** — requires step-up (existing assertion / approval-v2),
  not the TOFU path. Placeholder now; gated on backend. Backup/AddCredential
  **contract/vectors are merged as an inert slice**; runtime is lower priority
  than recovery because backup is not a flip blocker.
- **revoke runtime R3** — merged. Finish mutation landed with no-brick,
  head-binding, active_count>1, duplicate-revoke prevention,
  save-ok/anchor-fail recovery, anti-rollback, anti-oracle, and audit-integrity
  coverage. It remains default-off infrastructure, not the enforcement flip.
- **enforcement flip** — only after the pre-flip gates land.

---

## 8. Open decisions (were @tiana's; now via @code-reviewer / Caio)

- (Decided) Enrollment is a dedicated step, not a modal; skip is first-class.
- (Decided) 2-phase approval orchestrator split is merged and is the UI contract.
- (Decided) iOS "Protect your home" screen is merged. macOS enrollment uses
  engine-side owner identity over UDS with peer code-signing caller-auth plus
  constrained platform WebAuthn attestation; the UDS/no-PoP client foundation
  is merged, while the security-critical engine route and app integration remain
  pending.
- (Decided) iOS approval review screen is merged, default-off, with v1 fallback
  preserved. The app-wrapper preserves the B7 local-anchor pin before
  `confirm(prepared)`.
- (Decided) Pre-flip ordering: recovery-code/no-brick runtime first;
  backup/AddCredential contract is merged as inert infrastructure, but backup
  runtime waits behind the recovery semantics. Recovery does not count toward
  `active_count`; last-revoke remains blocked unless a future explicit
  recovery-backed operation is designed and reviewed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
