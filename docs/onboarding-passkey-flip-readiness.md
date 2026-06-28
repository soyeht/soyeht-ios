# Onboarding Passkey Flip Readiness

_Status as of 2026-06-28. This is a readiness checklist, not a flip approval._

The S3 owner-auth passkey work is code-complete for the backend mutation paths
that matter before enforcement: first enrollment, pair-machine approval-v2,
revoke, recovery consume, and backup/AddCredential are all merged as
default-off infrastructure. The default-off rollout/rollback control and its
env/Nix operational wiring are also merged, along with test-only evidence for
recovery provision under the real future reviewed-core rollout package. The
remaining work is the explicit enforcement flip decision/operation and the
product/security decision on macOS-local active finish.

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
- macOS local start/status are peer-auth capable through the UDS listener, but
  local finish still rejects with `local_attestation_constraints_unavailable`.
- The network/TCP router remains PoP-required and does not mount
  `/registration/local/*`.

This means merged runtime code is present, but users do not yet have active v2
owner-auth enforcement by default.

## Decision Gate: macOS-Local

Before the broader flip, Caio must choose one of these paths:

- **A-now:** build the separate Apple Anonymous attestation policy/path first.
  This is a new heavy objective. It must include an attested challenge/finish
  path, Apple root verification, UV, peer-auth, challenge binding, reliable
  backup-state policy if exposed, and source guards against falling back to the
  normal `Passkey` path.
- **B/defer:** keep macOS-local finish inert and proceed toward the broader
  flip using the existing iOS/PoP enrollment path for Mac users until safe
  server-side platform proof is solved.

Until Caio chooses, the security default remains B: local finish stays inert and
no credential is committed through the local macOS path.

## Flip Implementation Checklist

If B/defer is chosen, the flip must use the explicit production control added by
#195. It must not be an accidental constructor change or an implicit default
change.

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
- Keep macOS-local finish excluded from the flip unless A is separately built
  and accepted. The `/registration/local/finish` handler must remain inert in
  the B/defer path.
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
  on start and single-`Provision`/anchor-advance on finish; the flip PR still
  needs the full policy-on matrix and sign-offs.
- Source guards proving no local macOS finish activation in the B/defer path,
  no `/registration/local/*` on the TCP router, no TCP PoP bypass, and no
  fallback from active macOS-local work to the normal `Passkey` path.
- Cross-language vector checks for all owner-approval v2 contexts and wire
  shapes touched by the flip.
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
