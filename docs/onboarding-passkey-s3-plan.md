# Onboarding Passkey (Owner-Auth) — S3 iOS/macOS Plan & Status

_Status as of 2026-06-29. Owner of the Swift/SoyehtCore slice: @gianna.
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

**2026-06-29 decision update:** the A-now native macOS Touch ID/passkey
attestation path is no longer the active path to the flip. Hardware smoke
reached the Apple ceremony and the native platform-passkey surface refused
attestation ("Passkeys do not support attestation"). The merged macOS-local
request-shaping, peer-auth, fixture harness, and capture tooling remain
default-off/inert evidence infrastructure, but `/registration/local/finish`
stays excluded from the flip. The approved product direction is now:

- **Local Workspace:** Mac-only, local-only, no fan-out, no attestation claim.
- **Secure/Upgrade with iPhone:** required before multi-device, mesh, relay/VPN,
  or remote attach.
- **US-13 STOP:** encode a signed/verifiable strong-owner tier/provenance and
  Secure/Upgrade transcript before any Local Workspace can promote to
  multi-device. See
  `docs/local-workspace-trust-model.md`.

| Layer | Done | Notes |
|---|---|---|
| **Backend (theyos)** | ~99% | S0/S1/S2/S3a merged, default-off. Status/E1 is merged. Revoke R1/R2/R3 are merged. Recovery R0 provision/readiness, R1-A consume model, R1-B0 cross-log consumed helpers + combined consumable-head helper + consume-readiness classifier + fail-closed rate-limit adapter, recovery consume context/vectors, R1-B start-only/challenge-only runtime, R1-B finish/two-anchor repair runtime, backup/AddCredential contract/context vectors, backup/AddCredential composite wire vectors, backup/AddCredential start+finish runtime, macOS local engine M1 fail-closed foundation, M1b peer-auth/mount foundation, M1b platform-hint prep, A-now local Apple Anonymous proof/model inert foundation, A3 dangerous-conversion allowlist guard, A3 manual evidence harness, macOS-local attested-start wire vector, default-off owner-auth v2 rollout/rollback control plus env/Nix operational wiring, and reviewed-rollout evidence tests for recovery, core operations, and trust-state boundaries are merged. Native macOS platform-passkey attestation is blocked by Apple surface behavior, so active macOS-local finish is deferred and excluded from the flip. |
| **Client (soyeht-ios)** | ~89% | **Headless chain 100% merged**. iOS enrollment screen and approval review screen are merged. macOS UDS/no-PoP client foundation is merged. AddCredential composite wire DTO/vector consumer and headless client/orchestrator/ViewModel get-ahead are merged. The macOS-local attested-start decoder-tolerance vector and Dev.app minimal-capture front-half remain inert diagnostic/capture infrastructure. Local Workspace onboarding copy now offers Add iPhone or local Mac use, without an initial Linux fan-out CTA. AddCredential UI, explicit Mac approved/denied signaling, Secure/Upgrade with iPhone, and broader US-13 owner-tier client surfaces remain future work. |
| **Rollout / active-for-user** | **0%** | Inert by design; gated on pre-flip gates + the flip readiness checklist in `docs/onboarding-passkey-flip-readiness.md`. |

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
  consumed helpers + combined consumable-head helper + consume-readiness
  classifier + fail-closed rate-limit adapter ✅, recovery consume
  context/vectors ✅, R1-B start-only/challenge-only runtime ✅, R1-B
  finish/two-anchor repair runtime ✅, backup/AddCredential contract/context
  vectors ✅, backup/AddCredential composite wire vectors ✅,
  backup/AddCredential start-only/challenge-only runtime ✅, and
  backup/AddCredential finish/append+one-anchor runtime ✅. macOS local engine
  M1 fail-closed foundation ✅, M1b peer-auth/mount foundation ✅, M1b
  platform-hint prep ✅, A-now local Apple Anonymous proof/model inert
  foundation ✅, A3 dangerous-conversion allowlist guard ✅, A3 manual
  evidence harness ✅, macOS-local attested-start wire vector ✅,
  owner-auth v2 rollout/rollback control ✅,
  env/Nix rollout wiring + required-check path-filter coverage ✅, recovery
  provision reviewed-rollout evidence ✅, reviewed-rollout core operation
  evidence ✅, and reviewed-rollout trust-state boundary evidence ✅.
  **Remaining:** explicit flip decision/operation for the reviewed non-local
  owner-auth paths; US-13 owner-tier/provenance design before Local Workspace
  can promote to fan-out; active macOS-local finish is deferred because native
  Apple platform passkeys do not provide the A-now attestation proof.
- **Golden vectors** (Rust↔Swift): #166 registration, #167 adapter contract,
  #170 approval-v2 wire, #174 revoke-credential context, #178 recovery
  provision context, #179 AddCredential context, #184 RecoverCredential
  context, #200/#264 AddCredential composite start/finish wire wrappers, and
  #205/#270 macOS-local attested-start request-shaping/decoder-tolerance
  vectors.

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

**AddCredential get-ahead (optional, non-flip-blocking)**
- #264 — AddCredential composite start/finish wrapper DTOs + fixed-point tests
  over the #200 Rust-emitted canonical CBOR fixture. This pins the client-side
  consumer for `{v, registration, approval, context}` and
  `{v, context, registration, approval}`.
- #266 — the follow-up headless client slice adds the SoyehtCore HTTP client,
  dual-ceremony orchestrator, and ViewModel over those DTOs. It remains SPM-only
  and optional/non-flip-blocking: no AddCredential UI, runtime flip, or
  macOS-local finish activation.

**macOS-local attested-start tolerance (optional, non-flip-blocking)**
- #205 — theyos adds the canonical CBOR registration start-response vector for
  the A-now `/registration/local/start` request-shaping options: Direct Apple
  Anonymous attestation, platform attachment, user-verification-required,
  resident key, client-device hint, and enforced UV credential protection. This
  is server-emitted option shaping only, not Apple-chain proof and not a finish.
- #270 — SoyehtCore vendors the same fixture and proves the Swift lean
  registration decoder tolerates those extra fields while still consuming only
  the current `rp`/`user`/`challenge` view. It does not make the client honor
  attestation options, does not forward an `attestationObject`, and does not
  activate macOS-local finish.
- Dev.app minimal-capture slice — uses a live server-issued
  `/registration/local/start`, honors the API-applicable Apple attestation
  options through `ASAuthorization`, captures the resulting attestation, and
  writes an untracked local fixture compatible with the #204 harness. It stops
  before `/registration/local/finish`: no proof verdict, no commit/save/memory/
  anchor, no rollout, and no active enrollment. If the optional sanitized
  capture-result file is requested, it must use a different path from the raw
  fixture. The captured passkey is a throwaway/orphan credential and must be
  deleted after the dump; it must not be reused as an owner credential. Any
  future owner credential for a reviewed proof surface would require a fresh
  enrollment ceremony defined by that future STOP. Operator steps live in
  `docs/macos-local-attestation-capture-runbook.md`. The live capture requires
  the #206 Dev peer-auth selector and a normally signed `Soyeht Dev.app`.
  A later hardware smoke reached the native `ASAuthorization` ceremony and
  established that platform passkeys do not support the attestation required by
  A-now. This keeps the slice inert/diagnostic; it is not an active enrollment
  path and is no longer on the flip critical path.

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
  - AddCredential composite wrappers are vector-pinned: start response is
    `{v, registration, approval, context}` and finish request is
    `{v, context, registration, approval}`. The top-level AddCredential
    `context` is authoritative, `approval.context` is a mirror that must match,
    and the Swift decoder rejects a mismatched mirror before the future
    orchestrator can use it.
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
- macOS: native platform-passkey attestation is deferred for product use. The
  UDS/caller-auth/capture foundation remains merged and fail-closed, but it is
  diagnostic infrastructure, not an active owner enrollment path. The product
  direction is Local Workspace first, then Secure/Upgrade with iPhone before
  multi-device fan-out. TCP loopback or localhost + attestation alone is not
  authorization.
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

- **recovery-code** — the project owner: 1 passkey + 1 recovery at setup; pre-flip **blocker**.
  R0 provision/readiness is merged as default-off infrastructure, with
  shown-once recovery code semantics protected by the anchored/delivered/ready
  invariant. R1-A consume model, R1-B0 cross-log consumed helpers + combined
  consumable-head helper + consume-readiness classifier + fail-closed
  rate-limit adapter, and RecoverCredential context/vectors are merged as inert
  model/contract infrastructure; #187 adds the start-only/challenge-only
  runtime path that proves owner PoP, applies the fail-closed recovery-consume
  limiter before recovery-code comparison, checks the code, requires
  `Consumable`, and emits a registration challenge bound to the
  `RecoverCredential` context without mutating either authority or anchor.
  #188 adds the finish/two-anchor repair runtime: it revalidates the full
  `RecoverCredential` context byte-for-byte before registration finish,
  re-checks the recovery code under the same fail-closed limiter, appends the
  WebAuthn `RecoveryProof(X)` Add and recovery `Consume(X)` into one atomic
  `HouseholdAuthState` save, then advances anchors in WebAuthn-before-recovery
  order. Its repair path completes already-saved Add+Consume pairs without a
  live challenge and without a second Add/Consume. This closes the recovery
  no-brick code path in code, but it remains default-off infrastructure until
  the broader enforcement flip.
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
  - #185 added the consume-readiness classifier on top of those predicates:
    already verified and anchor-classified WebAuthn/recovery authorities
    classify as `Consumable`, `RepairRequired`, or `NotReady`. `Consumable` is
    only for an active recovery verifier head that matches the anchored head and
    is not consumed by either log; consumed heads classify as `RepairRequired`,
    and unanchored R0 provision/rotate tails remain `NotReady`.
  - #186 added the recovery-consume rate-limit adapter as inert runtime
    foundation: attempts are durably bucketed by `{hh_id, owner_p_id}`, limiter
    denials and limiter errors both collapse to the same `RejectOpaque` decision,
    and the adapter exposes no 429/header/status distinction. The future runtime
    must call it only after canonical body + owner PoP authenticate the
    household/owner bucket, and before recovery-code comparison or registration
    challenge consumption, so wrong-code attempts count without creating a
    bucket-burn oracle.
  - #187 added the recovery-consume start-only runtime: the handler uses the
    dedicated owner PoP operation, holds the mutation lock for a consistent
    read, calls the fail-closed limiter before `matches_code_bytes`, classifies
    both anchors read-only, requires `Consumable`, treats `active_count` only as
    telemetry, and starts a registration ceremony bound to the full
    `RecoverCredential` context. It intentionally does **not** finish
    registration, append WebAuthn `RecoveryProof` Add, append recovery
    `Consume`, save owner auth, or advance either anchor.
  - #188 added the recovery-consume finish/two-anchor repair runtime: the
    handler stays under the mutation lock, re-derives the same canonical
    `RecoverCredential` context and rejects on byte mismatch before
    `finish_registration_with_binding`, counts finish attempts with the
    fail-closed limiter before recovery-code comparison, appends Add+Consume
    with the same `RecoveryProof(X)`, saves the whole auth state atomically,
    updates memory, then advances the WebAuthn anchor before the recovery
    anchor. Repair runs before the normal path and completes already-saved
    Add+Consume pairs without needing a live registration challenge or signing a
    duplicate Add/Consume.
  - R1-B runtime eligibility is a deliberate break-glass decision: WebAuthn
    authority must be ever-enrolled with a valid/repairable anchor/prefix, and
    `active_count` is telemetry rather than permission. The recovery head is
    consumed if either the recovery log has `Consume(X)` or the WebAuthn log has
    an Add actor `RecoveryProof(X)`; repair must run before any new-Add gate.
    The Add is audit-visible; owner notification is a follow-up mitigation.
- **backup / 2nd passkey** — requires step-up (existing assertion / approval-v2),
  not the TOFU path. Backup/AddCredential **contract/vectors are merged as an
  inert slice**, and #189 adds the start-only/challenge-only runtime as
  default-off infrastructure. The start route proves owner PoP, classifies the
  WebAuthn authority read-only, requires `active_count > 0` as the step-up gate,
  starts two distinct ceremonies, and binds them to the same AddCredential
  context: the registration ceremony uses a canonical `add-credential`
  registration binding whose digest is `new_credential_binding_hash`, while the
  approval assertion challenge stores the full `OwnerApprovalContextV2`. The
  top-level `context` in the response is the authoritative context for the
  future finish echo; `approval.context` is a mirrored copy for decoder reuse and
  must match it. The start route intentionally does **not** finish registration,
  finish owner approval, append Add, save owner auth, or advance the WebAuthn
  anchor.
  #190 adds the finish/append+one-anchor runtime as default-off infrastructure:
  the handler keeps the top-level `context` authoritative, requires the nested
  approval mirror to match, re-derives the canonical AddCredential context from
  the live WebAuthn head/count, and rejects byte-for-byte mismatches before
  consuming either challenge. It checks the registration binding and owner
  approval context before calling `finish_registration_with_binding` and
  `finish_owner_approval_assertion`; the approval assertion must come from an
  active WebAuthn credential, and that credential becomes the `OwnerCredential`
  actor for the WebAuthn Add. The commit appends Add only, verifies the log,
  saves owner auth, updates memory, and advances the WebAuthn anchor. It does
  not touch recovery, revoke, last-revoke policy, TOFU, or PolicySnapshot, and
  it remains default-off infrastructure until the broader enforcement flip.
  #200/#264 add the vectors-first client get-ahead for AddCredential composite
  wire: Rust emits canonical CBOR for the start/finish wrappers, and SoyehtCore
  consumes the same fixture with thin DTOs and fixed-point tests. This pins the
  wrapper ordering, top-level-context/approval-mirror invariant, and
  registration-text vs approval-byte-string boundary. #266 builds the
  AddCredential HTTP client, dual-ceremony orchestrator,
  and ViewModel on top of those DTOs while still adding no UI, runtime flip, or
  macOS-local finish activation.
- **macOS local engine enrollment** — M1 foundation is merged as fail-closed
  backend infrastructure (#191), not as an active local enrollment runtime. It
  adds a separate local registration router with dedicated
  `/registration/local/{start,finish,status}` paths and a caller-auth boundary,
  but production defaults to no real verifier and therefore rejects before
  request decode or challenge staging. The fake verifier exists only in tests,
  the network/TCP router remains PoP-required and does not mount `/local/`, and
  local finish remains inert until M1b. #192 adds the M1b peer-auth/mount
  foundation: a dedicated UDS listener mounts only the local router, captures
  `LOCAL_PEERTOKEN` from the accepted `UnixStream`, injects mandatory peer
  metadata through `ConnectInfo`, and verifies the caller with
  audit-token -> SecCode -> designated-requirement. The production mount uses
  the production profile only (`com.soyeht.mac`); the dev bundle is a separate
  profile and is not accepted by the production verifier. Missing peer metadata,
  missing verifier, and denied callers still fail closed before decode or
  challenge staging. This makes start/status peer-auth capable, but **does not**
  make active local enrollment complete: local finish remains inert unless a
  future STOP defines a reviewed proof model and commit path.
  #193 adds the M1b attestation-prep/options slice for local start only: the
  local registration options now explicitly request
  `authenticatorAttachment=platform` and resident-key/discoverable credential
  behavior, while the TCP/PoP start path stays on the generic helper and local
  finish remains `local_attestation_constraints_unavailable`. This is
  request-shaping for the macOS ceremony, not a security proof: the platform
  attachment is only a client-side hint in the current WebAuthn wrapper. The
  active finish remains blocked until a reviewed proof model exists. Historical
  note: the project owner originally selected **A-now** for the Apple-grade local path, but
  the later hardware smoke showed the native platform-passkey surface does not
  provide the required attestation proof, so A-now is now deferred rather than a
  pending commit slice. #201 adds the attested
  local-start foundation: local start requests Direct Apple Anonymous
  attestation with platform attachment, UV required, resident/discoverable
  behavior, and no-sync request shaping, and stages a separate
  `LocalAttestedRegistration` challenge that the normal `Passkey` finish cannot
  consume. #202 adds the A2 proof/model inert foundation: an Apple-only pinned
  WebAuthn root policy, core verification helper, and typed
  `VerifiedLocalAppleAttestedCredential` proof object after AppleAnonymous +
  AnonCa + UV + BE=false + BS=false checks. The HTTP `/registration/local/finish`
  handler still does not call that helper and still returns
  `local_attestation_constraints_unavailable`; #202 does not save owner auth,
  write memory, advance anchors, flip rollout, or activate local enrollment.
  #203 adds the A3-prep dangerous-conversion guard: runtime Rust sources under
  `admin/rust/**/src` are scanned so `Credential -> Passkey` conversion remains
  allowlisted to the local attested proof-object helper. This is defense in
  depth around `danger-credential-internals`, not active finish readiness. #204
  adds an evidence-only manual hardware harness/runbook for a fresh Apple
  Anonymous attestation fixture. The harness is ignored by default, reads only
  an untracked local fixture, routes it through the same pinned Apple-root A2
  verifier and five checks, and emits only sanitized verdict fields
  (format/UV/BE/BS/root policy/fingerprint). It also records that public
  `webauthn-rs-core 0.5.5` has no safe public `verify_at` seam, so the expired
  Apple fixture remains negative-only evidence. #204 is the mechanism for the
  A3 evidence gate, not the verdict. The native hardware run did not produce a
  positive attested fixture because Apple platform passkeys refused attestation;
  therefore active macOS-local finish remains excluded from the flip unless a
  future STOP defines a new proof surface. #205/#270 add the hardware-free
  `/local/start` request-shaping and
  Swift decoder-tolerance vector: it pins the Direct Apple
  Anonymous/platform/UV/resident option wrapper and proves the current Swift
  lean decoder does not break on those extras. This is not a positive hardware
  verdict, not client honoring of the attestation options, and not active finish
  readiness. Any future hardware evidence for a new proof surface would need a
  live server-issued challenge, a fixture produced by that reviewed surface, and
  #204-style verification; that smoke would prove Apple chain + the five checks
  + internal consistency only if a valid attested fixture exists. The current
  native platform-passkey surface could not produce one. Server-issued challenge
  binding, single-use, and anti-replay remain properties of any future
  active-commit design. The historical capture runbook is
  `docs/macos-local-attestation-capture-runbook.md`; it depends on the #206 Dev
  peer-auth selector and a normally signed `Soyeht Dev.app`.
- **owner-auth v2 rollout control** — #195 adds the default-off production
  control for the eventual flip, and #196 wires it into `.env.example`, the Nix
  module/template, and install rendering with `legacy` as the operational
  default. `THEYOS_OWNER_AUTH_V2_ROLLOUT=reviewed-core-v2` enables the reviewed
  core policies; absent, empty, `off`, `legacy`, `legacy-only`, and unknown
  values all preserve `LegacyOnly` (unknown values warn and fail safe). Nix
  config restricts the rendered value to `legacy | reviewed-core-v2`, so deploy
  typos fail at config/build time while manual env typos still fail safe at
  runtime. Removing or changing the env value and restarting/rebuilding gives a
  clean env/bootstrap rollback to `LegacyOnly` with the v1/legacy path
  preserved. #196 also expands the required Backend CI and Homebrew smoke path
  filters to cover `.env.example`, `nix/**`, and `tests/nixos-install/**`, so
  deploy/env/Nix changes materialize the required checks instead of requiring a
  docs-only-style bypass.
  Recovery uses a dedicated `RecoveryCodeEnforcement::BreakGlassEnabled`
  switch, not active-credential v2 semantics: recovery consume remains
  break-glass, and `active_count=0` stays valid when the recovery-code gates
  pass. This is still not the flip; production remains default-off until the project owner's
  flip decision and the required sign-offs.
- **reviewed-rollout evidence** — #197 adds a test-only guard under the real
  future `OwnerApprovalEnforcementPolicy::reviewed_core_v2_rollout()` package for
  recovery provision. It proves `start` emits `ProvisionRecoveryCode` while
  staying challenge-only with no recovery-anchor write, and that `finish`
  persists exactly one `Provision` and advances the recovery anchor. #198 extends
  the same evidence to the core active-credential operations by running
  pair-machine approval-v2, revoke start/finish, and AddCredential start/finish
  happy paths under the same future rollout package. #199 pins the pair-machine
  trust-state boundary under that package: NeverEnrolled keeps the legacy path,
  Active is covered by #198, and RecoveryRequired or AnchorInvalid fail closed
  with opaque rejects and no mutation. This is evidence for the future flip
  package, not a default change or active enforcement.
- **revoke runtime R3** — merged. Finish mutation landed with no-brick,
  head-binding, active_count>1, duplicate-revoke prevention,
  save-ok/anchor-fail recovery, anti-rollback, anti-oracle, and audit-integrity
  coverage. It remains default-off infrastructure, not the enforcement flip.
- **enforcement flip** — only after the pre-flip gates land. The current
  readiness checklist lives in `docs/onboarding-passkey-flip-readiness.md` and
  keeps macOS-local active finish excluded. The approved macOS product direction
  is Local Workspace plus Secure/Upgrade with iPhone before fan-out; US-13 owns
  the owner-tier/provenance design for that transition.

---

## 8. Open decisions (were the prior reviewer's; now via @code-reviewer / the project owner)

- (Decided) Enrollment is a dedicated step, not a modal; skip is first-class.
- (Decided) 2-phase approval orchestrator split is merged and is the UI contract.
- (Decided) iOS "Protect your home" screen is merged. Historical macOS-local
  enrollment work uses engine-side owner identity over UDS with peer
  code-signing caller-auth, but the constrained platform WebAuthn-attestation
  path is now superseded/deferred by the native platform-passkey finding. The
  UDS/no-PoP client foundation remains inert diagnostic infrastructure; current
  product direction is Local Workspace plus Secure/Upgrade with iPhone before
  fan-out.
- (Superseded) macOS local active finish sequencing: the project owner originally chose
  A-now, and #201/#202 merged inert start/staging and A2 proof/model foundations.
  Hardware smoke later showed native Apple platform passkeys do not provide the
  required attestation proof, so A-now is deferred and `/registration/local/finish`
  remains hard-inert/excluded from the flip.
- (Decided) Product direction after A-now defer: Mac Local Workspace is allowed
  as local-only, and any promotion to multi-device/mesh/relay/VPN/remote attach
  requires Secure/Upgrade with iPhone. US-13 has staged signed/verifiable
  owner-tier/provenance schema, App-Attest-specific provenance names,
  Secure/Upgrade transcript vectors, and the pair-machine reviewed-v2 gate.
  Device-pairing approve, household remote attach, and Product A / relay-stream
  are STOP-source-guarded against accidental `reviewed-core-v2` /
  `owner_can_fan_out()` coupling; backend proof verification, runtime strong-tier
  minting, and default-safe fan-out gates must still land before that fan-out can
  become active.
- (Decided) iOS approval review screen is merged, default-off, with v1 fallback
  preserved. The app-wrapper preserves the B7 local-anchor pin before
  `confirm(prepared)`.
- (Decided) Pre-flip ordering: recovery-code/no-brick runtime first; the
  start+finish runtime is now merged as default-off infrastructure.
  Backup/AddCredential contract and start+finish runtime are merged as
  default-off infrastructure.
  Recovery does not count toward `active_count`; last-revoke remains blocked
  unless a future explicit recovery-backed operation is designed and reviewed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
