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
| **Backend (theyos)** | ~85% | S0/S1/S2/S3a merged, default-off. Pre-flip gates: 4 done; **3 remaining** (backup/step-up, recovery-code, status/E1) + the enforcement flip still gated. |
| **Client (soyeht-ios)** | ~50% | **Headless chain 100% merged**; UI/screens 0%. |
| **Rollout / active-for-user** | **0%** | Inert by design; gated on pre-flip gates + the flip. |

---

## 3. Backend (theyos) — merged, default-off

- **S0/S1/S2/S3a** merged. S2 = server-side challenge binding + anti-rollback
  authority anchor + pair-machine-approve handler wiring. S3a = owner passkey
  enrollment backend (genesis TOFU).
- **Pre-flip gates** (apply before flipping enforcement): double-prepare ✅,
  sign_count policy ✅, PolicySnapshot/trust-state ✅, dedicated enrollment op
  `OwnerAuthEnrollInitial` ✅. **Remaining:** backup/subsequent enrollment
  (step-up), recovery-code, status/E1 anchor-lag-tolerant endpoint.
- **Golden vectors** (Rust↔Swift): #166 registration, #167 adapter contract,
  #170 approval-v2 wire.

---

## 4. Client (soyeht-ios) — headless chain COMPLETE (merged)

All in `Packages/SoyehtCore` (SPM, unit-tested, inert).

**Enrollment**
- #215 — registration DTOs (parity)
- #216 — `PasskeyProvider` registration ceremony
- #217 — in-flight cancellation
- #218 — `OwnerPasskeyEnrollmentClient` (HTTP/CBOR/PoP)
- #220 — `PasskeyProvider.authenticate` (assertion ceremony; unified `runCeremony<T>`)

**Approval-v2**
- #219 — `OwnerApprovalContextV2` DTO + challenge-digest
- #222 — wire DTOs: `OwnerApprovalV2`/`OwnerApprovalV2Finish` encoders +
  `OwnerApprovalV2StartResponse` decoder
- #223 — `OwnerApprovalV2Client` (`start` / `approveV2`)
- #224 — `OwnerApprovalV2Orchestrator` (headless coordinator)

**Fase-2 config (parallel track, orthogonal)**
- #221 — `OnboardingConfig` timeout SSOT (inert)
- #225 — first caller migration (`HouseholdPairingService`)
- #226 — next migration (`HouseNamingFromiPhoneView`, in flight)

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
  **never branch on `BootstrapError.code`**. Future UI rule: branch only on HTTP `200`.
- **PoP** fresh-per-request, bound to `method + pathAndQuery + body`.

---

## 6. Remaining — UI / app-target (not started)

**6a. 2-phase orchestrator refactor** (next slice, headless SPM, contract locked, GO given):
- `PreparedOwnerApprovalV2 { cursor: UInt64, startResponse: OwnerApprovalV2StartResponse }` (Sendable value-type)
- `prepare(cursor:) -> PreparedOwnerApprovalV2` (start only → UI renders context)
- `confirm(_ prepared:) -> Void` (authenticate opaque + build exact-context envelope + approveV2)
- keep `approve(cursor:)` convenience = `confirm(try await prepare(cursor:))` (#224's 5 tests stay)
- _Why:_ #224's single-shot `approve` can't show a context-review screen between
  `start` and the system passkey sheet; the 2-phase split gives the UI that point.

**6b. Screens (app-target / source-guard — no CI live ceremony):**
- Enrollment passkey #1 — iOS: after `HouseholdPairingService.pair()`
  (`HouseNamingFromiPhoneView.swift:285-301`), before `onNamed()`→`showMainStoryboard`
  (`AppDelegate:478-485`). macOS: new `BootstrapStep.ownerPasskeyEnrollment` between
  `HouseCreationProgressView.onCreated` (:134) and `.houseCard` (`WelcomeRootView`).
- Approval review screen — renders `startResponse.context` before the gesture; the
  v2 path is gated (policy=v2; v1 default) at `HouseholdMachineJoinRuntime` submitAction.
  macOS founder hook: `WelcomeOnboardingState.approving` (`WelcomeRootView:175`, currently unconsumed).
- `skip`/"set up later" is first-class (skip → NeverEnrolled → legacy).

**Test boundary:** ViewModels + the 2-phase orchestrator are SPM-headless-testable
(inject clients/provider/seam). SwiftUI views, the live `ASAuthorization` ceremony,
the `.approving` view + nav wiring (macOS), and `AppDelegate` routing (iOS) are
app-target / **source-guard only** (cannot run live in CI — xcframework caveat).

---

## 7. Gated / pre-flip (NOT in scope yet)

- **recovery-code** — Caio: 1 passkey + 1 recovery at setup; pre-flip **blocker**
  (contract #3 needs pre-provisioned recovery for revoke-last). Placeholder in UI now; real flow gated on backend.
- **backup / 2nd passkey** — requires step-up (existing assertion / approval-v2),
  not the TOFU path. Placeholder now; gated on backend.
- **status / E1** (committed-401 recovery) — needs a durable post-save/pre-anchor
  marker or exact-genesis repair; UI must not depend on it.
- **enforcement flip** — only after the pre-flip gates land.

---

## 8. Open decisions (were @tiana's; now via @code-reviewer / Caio)

- Enrollment: dedicated step vs modal (post-pairing / HouseCard)?
- Approval v2: inert plumbing only now (v1 default) vs ship the review screen?
- Ordering: enrollment VM first vs approval?
- (Decided) 2-phase orchestrator split — **approved**, contract locked (§6a).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
