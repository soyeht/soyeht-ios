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
| **Backend (theyos)** | ~90% | S0/S1/S2/S3a merged, default-off. Status/E1 is merged. Revoke R1 contract/vectors + R2 start challenge are merged; revoke finish mutation and recovery/backup gates remain. |
| **Client (soyeht-ios)** | ~75% | **Headless chain 100% merged**. iOS enrollment screen is merged; approval review VM is merged. Approval review screen and macOS enrollment architecture remain. |
| **Rollout / active-for-user** | **0%** | Inert by design; gated on pre-flip gates + the flip. |

---

## 3. Backend (theyos) — merged, default-off

- **S0/S1/S2/S3a** merged. S2 = server-side challenge binding + anti-rollback
  authority anchor + pair-machine-approve handler wiring. S3a = owner passkey
  enrollment backend (genesis TOFU).
- **Pre-flip gates** (apply before flipping enforcement): double-prepare ✅,
  sign_count policy ✅, PolicySnapshot/trust-state ✅, dedicated enrollment op
  `OwnerAuthEnrollInitial` ✅, status/E1 marker-backed endpoint ✅. Revoke
  R1 contract/vectors ✅ and R2 start/challenge ✅. **Remaining:**
  backup/subsequent enrollment (step-up), recovery-code/no-brick, revoke R3
  finish mutation, and the flip.
- **Golden vectors** (Rust↔Swift): #166 registration, #167 adapter contract,
  #170 approval-v2 wire, #174 revoke-credential context.

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
- macOS: still gated. It is not a direct iOS port: the founder Mac flow does not
  currently expose owner identity / PoP signer material to the app target. Choose
  the macOS identity/PoP architecture before adding `.enrollPasskey` after
  `houseCard`.
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

**6c. Approval review screen** (next app-target slice):
- Renders the pair-machine context fields (op, machine id, addr, transport) before
  the owner can tap Approve. `confirm` is reachable only after explicit owner
  approval; it is never triggered automatically after `prepare`.
- Source guards should prove the view renders context before confirm, calls
  confirm only from the explicit Approve action, does not reference
  `BootstrapError` / `.code`, and does not touch the challenge.
- The v2 path remains gated (policy=v2; v1 default) at the pair-machine approval
  submit action. No backup/subsequent path or non-pair-machine operation is
  exposed here.

**Test boundary:** SPM already covers the enrollment ViewModel, orchestrators,
clients, CBOR wire, status/E1, anti-oracle state transitions, and the approval
review VM. SwiftUI views, live
`ASAuthorization`, app navigation, and source guards are app-target / **CI-only**
because of the xcframework caveat; no local live ceremony is required.

---

## 7. Gated / pre-flip (NOT in scope yet)

- **recovery-code** — Caio: 1 passkey + 1 recovery at setup; pre-flip **blocker**
  (contract #3 needs pre-provisioned recovery for revoke-last). Placeholder in UI now; real flow gated on backend.
- **backup / 2nd passkey** — requires step-up (existing assertion / approval-v2),
  not the TOFU path. Placeholder now; gated on backend.
- **revoke runtime R3** — R1 contract/vectors and R2 start/challenge are merged;
  finish mutation remains gated on no-brick, head-binding, active_count>1,
  duplicate-revoke prevention, save-ok/anchor-fail recovery, and anti-rollback.
- **enforcement flip** — only after the pre-flip gates land.

---

## 8. Open decisions (were @tiana's; now via @code-reviewer / Caio)

- (Decided) Enrollment is a dedicated step, not a modal; skip is first-class.
- (Decided) 2-phase approval orchestrator split is merged and is the UI contract.
- (Decided) iOS "Protect your home" screen is merged. macOS enrollment waits on
  the founder identity/PoP architecture decision.
- (Pending) Approval review screen exact copy/layout and app-target rollout gate.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
