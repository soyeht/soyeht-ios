# Onboarding Passkey Flip Readiness

_Status as of 2026-06-28. This is a readiness checklist, not a flip approval._

The S3 owner-auth passkey work is code-complete for the backend mutation paths
that matter before enforcement: first enrollment, pair-machine approval-v2,
revoke, recovery consume, and backup/AddCredential are all merged as
default-off infrastructure. The default-off rollout/rollback control and its
env/Nix operational wiring are also merged, along with test-only evidence for
the reviewed core operations and trust-state boundaries under the real future
reviewed-core rollout package. The A3 manual evidence harness and the
macOS-local attested-start request-shaping/decoder-tolerance vectors are also
merged, but the positive hardware verdict and active-commit slice remain
pending. The remaining work is the explicit enforcement flip decision/operation
and the A3 active-commit slice for macOS-local active finish.

## Current Default

The current product state is still inert:

- `OwnerApprovalEnforcementPolicy::default()` is `LegacyOnly` for every
  operation.
- `OwnerEventsRouterState::new(...)` installs that default policy unless an
  explicit policy is provided.
- The daemon router construction in `household_bootstrap.rs` reads
  `THEYOS_OWNER_AUTH_V2_ROLLOUT`; absent, empty, `off`, `legacy`,
  `legacy-only`, and unknown values all preserve `LegacyOnly`.
- The deployment templates now render that env var as `legacy` by default; the
  Nix option only accepts `legacy` or `reviewed-core-v2`.
- The only reviewed-core activation value is `reviewed-core-v2`; setting that
  value is still a future flip operation and requires the sign-offs below.
- macOS local start/status are peer-auth capable through the UDS listener. The
  A-now attested-start and A2 proof/model foundations are merged, but local
  finish still rejects with `local_attestation_constraints_unavailable`.
- The network/TCP router remains PoP-required and does not mount
  `/registration/local/*`.

This means merged runtime code is present, but users do not yet have active v2
owner-auth enforcement by default.

## Decision Gate: macOS-Local

Caio selected **A-now** for the macOS-local path. That is a strategy decision,
not active local enrollment:

- #201 stages a separate local attested registration challenge and requests
  Direct Apple Anonymous/platform/UV/resident/no-sync ceremony options.
- #202 adds the A2 proof/model inert foundation: Apple-only pinned root policy,
  core verification helper, and typed proof object after AppleAnonymous,
  AnonCa, UV=true, BE=false, and BS=false checks.
- #203 adds the A3-prep source guard for the dangerous `Credential -> Passkey`
  conversion, allowlisting it to the local attested proof-object helper across
  runtime Rust sources.
- #204 adds an evidence-only manual hardware harness/runbook for a fresh Apple
  Anonymous attestation fixture. It documents that public `webauthn-rs-core`
  has no safe public `verify_at` seam, so the expired Apple fixture remains
  negative-only evidence. The harness reads only an untracked local fixture and
  emits sanitized verdict fields; it does not provide a positive verdict by
  itself.
- #205/#270 add the hardware-free `/local/start` request-shaping and Swift
  decoder-tolerance vector. They pin the Direct Apple Anonymous/platform/UV/
  resident option wrapper and prove the current Swift lean decoder tolerates
  those extra fields. They do not make the client honor the options, do not
  forward an `attestationObject`, and are not a positive hardware verdict.
- The Dev.app minimal-capture front-half adds the client mechanism for a
  fresh hardware fixture: it uses a live server-issued `/registration/local/start`,
  asks `ASAuthorization` for the API-applicable attestation/UV options, writes the
  raw result only to the explicit untracked fixture path, and stops before local
  finish. Any optional sanitized capture-result file must use a different path
  from the raw fixture. It does not produce a proof verdict, commit a credential,
  or activate enrollment. The captured passkey is throwaway evidence and must be
  deleted after the dump; the real owner credential is enrolled fresh in A3. The
  operator runbook is `docs/macos-local-attestation-capture-runbook.md`. It
  requires the #206 Dev peer-auth selector and a normally signed `Soyeht Dev.app`
  so the isolated `SoyehtDev` engine verifies `com.soyeht.mac.dev`.
- The HTTP `/registration/local/finish` handler still remains hard-inert. It
  does not consume the proof helper, save owner auth, write memory, advance
  anchors, or activate local enrollment.

A3 is still required before macOS-local finish can become active. It must add
positive end-to-end Apple-chain evidence by running the #204 harness against a
fresh hardware capture, keep the #203 conversion guard enforced, revalidate
`NeverEnrolled`/authority-empty under lock, store evidence, preserve commit
ordering, and cover replay plus anchor-failure behavior. Until A3 lands and is
signed off, no credential is committed through the local macOS path.

## Flip Implementation Checklist

The flip must use the explicit production control added by #195. It must not be
an accidental constructor change or an implicit default change.

- Use `THEYOS_OWNER_AUTH_V2_ROLLOUT=reviewed-core-v2` to turn on the approved
  per-operation policies. Pair-machine approval, revoke, and AddCredential use
  active-credential v2 semantics; recovery provision/rotate/consume uses the
  dedicated recovery-code policy switch while preserving the reviewed
  break-glass semantics, not an active-count gate.
- Keep the operational default at `legacy` until the flip decision. The Nix
  module/template and `.env.example` must continue to make `reviewed-core-v2`
  an explicit opt-in value, not a default or truthy shorthand.
- Preserve the rollback lever: operators must be able to remove/change the env
  value and restart/rebuild the router to return the policy to `LegacyOnly`
  cleanly, with the legacy/v1 path preserved for active users, if the flip
  shows a production issue. A live no-restart rollback toggle is not part of
  #195 unless a future slice adds it.
- Keep first enrollment as the dedicated `OwnerAuthEnrollInitial` path. The
  pair-machine policy must still fall back to legacy for `NeverEnrolled`, require
  v2 for `Active`, and fail closed for `RecoveryRequired` or `AnchorInvalid`.
- Require production wiring for the WebAuthn RP, WebAuthn authority anchor,
  recovery anchor, and recovery-consume limiter before policy-on paths can be
  treated as ready. Missing infrastructure must reject opaquely or prevent the
  flip from being considered healthy.
- Keep macOS-local finish excluded from the flip unless A3 is separately built
  and accepted. The `/registration/local/finish` handler must remain inert until
  the verified proof object is committed through the reviewed active path.
- Keep the iOS/macOS client feature gates explicit. Default-off UI paths should
  become active only under the same rollout decision, with v1 fallback preserved
  where the backend policy says `LegacyV1`.
- Do not relax recovery/last-revoke boundaries. Recovery remains a separate
  factor and does not count in WebAuthn `active_count`; normal last-revoke stays
  blocked unless a separate recovery-backed operation is designed and reviewed.

## Verification Checklist

Evidence for a flip PR should include:

- Rust tests for default-off behavior and policy-on behavior for pair-machine
  approval-v2, revoke, recovery provision/consume, and AddCredential, including
  the recovery break-glass semantics.
  #197 already pins recovery provision under
  `OwnerApprovalEnforcementPolicy::reviewed_core_v2_rollout()` as challenge-only
  on start and single-`Provision`/anchor-advance on finish. #198 pins
  pair-machine approval-v2, revoke start/finish, and AddCredential start/finish
  under the same future rollout package. #199 pins the pair-machine
  per-trust-state boundary under that package: NeverEnrolled falls back to
  legacy, Active is covered by #198, and RecoveryRequired or AnchorInvalid fail
  closed with opaque rejects and no mutation. The flip PR still needs the final
  policy-on review/sign-offs and any release-specific evidence.
- Source guards proving no local macOS finish activation before A3,
  no `/registration/local/*` on the TCP router, no TCP PoP bypass, and no
  fallback from active macOS-local work to the normal `Passkey` path.
  #202 already pins the A2 proof/model inert foundation: Apple-only root policy,
  typed `VerifiedLocalAppleAttestedCredential`, and no HTTP local-finish call to
  the proof helper. #203 adds a workspace-aware allowlist guard so the dangerous
  `Credential -> Passkey` conversion remains confined to that proof-object
  helper. #204 adds the manual evidence harness, but the flip/A3 gate still
  needs a reviewed positive Apple-chain verdict from a fresh hardware capture
  before active commit.
- Cross-language vector checks for all owner-approval v2 contexts and wire
  shapes touched by the flip. #200/#264 already pin the AddCredential
  composite start/finish wrappers byte-for-byte across Rust and Swift; that is
  evidence for the client/orchestration path, not a default change or active
  enforcement. #266 adds the AddCredential SoyehtCore headless HTTP client,
  dual-ceremony orchestrator, and ViewModel on top of those vectors; it still
  does not add UI, flip the rollout, or activate macOS-local finish.
  #205/#270 pin the macOS-local attested-start option wrapper byte-for-byte
  across Rust and Swift, and prove decoder tolerance only. Hardware evidence
  still must use a live server-issued `/registration/local/start` capture, not
  the synthetic vector. The #204 harness smoke proves Apple chain + the five
  checks + internal consistency; server challenge binding, single-use, and
  anti-replay remain A3 active-commit evidence. The capture runbook is
  `docs/macos-local-attestation-capture-runbook.md`; it depends on the #206 Dev
  peer-auth selector and a normally signed `Soyeht Dev.app`.
- Swift tests for the enrollment and approval-review ViewModels and app gating,
  plus CI coverage for the SwiftUI/app-target source guards.
- `git diff --check` and a privacy scan over any docs, fixtures, PR body, and
  test data.
- Required CI path filters must keep covering rollout deploy surfaces such as
  `.env.example`, `nix/**`, and `tests/nixos-install/**`; rollout/deploy PRs
  are code/process changes, not docs-only bypass candidates.
- Explicit sign-off from backend/security, architecture, client, and governance
  reviewers. The flip itself remains a Caio decision.

## Non-Goals

- Do not use the current macOS `authenticatorAttachment=platform` option as
  server-side proof. It is request shaping only.
- Do not admin-bypass required CI for code, contracts, fixtures, or runtime
  changes. The prior admin merge exception was docs-only and path-filtered.
- Do not treat this runbook as release authorization, notarization approval, or
  live validation. Those remain separate release gates.
