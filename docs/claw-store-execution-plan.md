# Claw Store Execution Plan

Updated: 2026-06-23

This is the active execution plan for raising the Soyeht Claw Store
architecture score across theyos, iOS, and macOS. It is a planning document,
not release authorization.

Do not touch the installed `/Applications/Soyeht.app`. Use Dev builds and CI
only. Keep Product A, nvpn, mesh routing, `10.44.0.0/16`, ClawShareBridge, and
release/deploy/pin work out of this plan unless the user explicitly authorizes
that separate track.

## Operating Model

The goal is no longer to ask for the next micro-task after every PR. Work moves
through larger, bounded packages with clear stop points.

Default flow:

1. Implement one coherent package.
2. Run local focused validation.
3. Open PR.
4. Review diff for scope, privacy, Product A/nvpn leakage, and compatibility.
5. Wait for full CI green.
6. Merge only after CI is green.
7. Immediately dispatch the next approved package.

Stop and ask before:

- breaking or versioning public wire behavior;
- receive-side hardening that rejects data previously accepted;
- destructive storage migration;
- changing lease/capacity policy;
- release, deploy, tag, pin, notarization, or shipping app validation;
- Product A/nvpn/mesh integration;
- touching `/Applications/Soyeht.app`;
- changing keychain account semantics or credential ownership;
- normalizing Claw Store status codes across surfaces without a compatibility
  plan.

## Recently Completed

These should not be rediscovered or reimplemented.

- theyos #125: cross-repo contract workflow now checks `soyeht/soyeht-ios`;
  contract runbook added.
- theyos #126 and soyeht-ios #199: `list_item_catalog_only` fixture is covered
  by Rust golden serialization and Swift decode.
- soyeht-ios #200: `BootstrapAcceptHouseholdConfirmClient` now gates with
  `EngineCompat.assertCompatible` before the mutating confirm POST.
- theyos #127: typed IPC protocol vocabulary added in `core-rs`.
- theyos #128: executor to vmrunner method producers now use `VmRunnerOp`.
- theyos #129: executor to store method producers now use `StoreOp`.
- theyos #130: executor lease owner/kind producers now use typed vocabulary.
- theyos #131: server lease owner/kind producers migrated.
- theyos #132: broad source guard prevents reintroduced stringly IPC/lease
  producers.
- theyos #133: enum to dispatch parity guard added; dead store calls fixed or
  removed.
- theyos #134: `WarmPoolSlotId` owns `"{claw_type}:slot:0"` for warm-pool lease
  owner IDs.
- theyos #135: store lease APIs typed with the core protocol lease vocabulary
  while preserving raw IPC receive compatibility.
- theyos #136: IPC request envelope has optional protocol-version plumbing with
  byte-identical legacy emission by default.
- theyos #137: lease, warm-pool, and capacity invariants pinned with
  tests-first coverage.
- theyos #138: macOS runner warm-pool disk gate added and fail-closed
  panic/lease behavior pinned.
- theyos #139: opt-in live VZ validation harness and runbook added; default CI
  remains inert.
- soyeht-ios #201: macOS Claw Store grid and detail now gate
  install/retry/deploy on guest-image readiness; uninstall/open terminal remain
  available.
- theyos #140: PoP/Operation gate-completeness guard added for household routes
  and owner add-machine handlers.
- theyos #141: PoP/CBOR cross-language golden vectors added on the Rust side
  for `RequestSigningContext` and `PairingProofContext`.
- soyeht-ios #202: Swift `HouseholdCBOR` parity tests added for the theyos
  PoP/CBOR vectors; Rust and Swift match byte-for-byte with no drift.
- theyos #142, #143, #144, #145 (P7-C / P7-D): rate-limit coverage guard
  (test-only), additive per-action threshold API (behavior-neutral), per-person
  `429` on household Claw install/uninstall, and a pre-auth gate-ordering guard.
  Rate limiting is wired and live; no rate-limit inventory remains.
- theyos #146 and #147: macOS-VZ supportability seam
  (`VZError::VirtualizationUnsupported`) plus a `vz::preflight_vz_supportability()`
  gate on all 7 macOS-VZ start sites (source guard pins the count).
- theyos #148, #149, #150: gate admin instance create on macOS guest-image
  readiness behind a shared helper; converge the two create pipelines into
  `create_instance_core` with characterization guards.
- theyos #151 and soyeht-ios #205: `virtualization_unavailable` guest-image
  failure code (core-rs), surfaced on iOS as a terminal no-CTA failure.
- theyos #152 and soyeht-ios #206: typed `BootstrapErrorCode` end-to-end
  (household-rs enum + cross-language fixture; iOS bootstrap consumers).
- theyos #153 and soyeht-ios #207: typed `InstanceStatus` lifecycle wire —
  cross-language fixture + parity guard (store-rs) mirrored as a fail-soft Swift
  enum across the create/poll/list models.
- theyos #154: claw install/uninstall job-leak rollback + atomic `ClawStore`
  `set_state` / `mark_not_installed` (no orphaned job and no transitional status
  drift on a failed mark).
- soyeht-ios #203 and #204 (P6-B / P6-C): macOS Claw Store reason-coded
  guest-image recovery banner + "Check Again", and a mutating "Try Again"
  (prepare) through the shared prepare client.
- soyeht-ios #208 (merged): test-only source-guard asserting the macOS recovery
  surfaces stay reason-coded (no raw daemon/VZ strings as primary UI, SSOT pinned
  on `MacGuestImageRecovery` / `GuestImageRecoveryPolicy`).

## Current Active Package

None. The Package queue below (P1-P8) is closed, or its remaining items are
backlog / human-stop-point — see each package's updated status. The honest next
step is plan maintenance plus a fresh architecture-score review to pick the next
objective, not another micro-PR on a closed queue.

### P7-C: Rate-Limit Coverage — DONE, no action

Closed via theyos #142 (rate-limit coverage guard, test-only), #143 (additive
per-action threshold API, behavior-neutral), #144 (per-person `429` on household
Claw install/uninstall), and #145 (pre-auth gate-ordering guard, test-only). Rate
limiting is wired and live. Do not re-run this as a read-only inventory.

## Next Execution Queue

The central thesis after fresh architecture review is: stop spending most of
the effort on areas already strong enough. Claw Store contract, iOS fixtures,
and route parity are mature enough for now. The real score valley is backend
runner/IPC/lease ownership, Mac runner/VZ trust, and Mac client readiness
parity.

Queue status (refreshed): those valleys have now been substantially addressed.
Packages 1-8 below are closed, or their remaining items are backlog /
human-stop-point (see each Status). What remains is not another micro-PR on this
queue. The honest next steps are: (1) plan/doc maintenance (this refresh);
(2) the Package 3 deeper lease-ownership refactor ONLY after a fresh read-only
scoping pass confirms it clears the bar without a triggering bug; (3) VZ/live
validation, which stays a human stop-point; or (4) a fresh architecture-score
review to define a new objective. Do not re-open closed packages.

### Package 1: B4b Completion

Status: completed in theyos #135.

Merge B4b after CI green. Do not turn this into receive-side hardening. B4b is
complete only when the store-rs dead enums are gone, production lease APIs are
typed, and `store_ipc.rs` still accepts the same raw wire values as before.

Expected lift:

- Linux/vmrunner/backend: medium.
- SSOT/discoverability: medium.
- Mac runner/macOS engine: small indirect lift.

### Package 2: IPC Envelope And Versioning, Additive

Status: completed in theyos #136 as plumb-only optional request versioning.

Problem:

Method producers are now typed, but the IPC envelope is still not a complete
versioned contract end to end. Without an additive envelope/version path, future
receiver hardening or protocol evolution will still be risky.

Objective:

- introduce narrow protocol versioning and typed builders without breaking old
  clients;
- preserve raw legacy receive compatibility;
- add round-trip and compatibility tests that prove old wire still works.

Likely files:

- theyos `core-rs/src/ipc/protocol.rs`;
- theyos `core-rs/src/ipc/wire.rs`;
- theyos IPC clients/producers in executor, vmrunner, vmrunner-macos, and
  store where version fields/builders are introduced.

Allowed:

- additive `protocol_version` fields where skipped/optional for old wire;
- typed request builders/adapters;
- legacy raw accept tests.

Forbidden:

- rejecting old requests;
- renaming method strings;
- changing response/error shape;
- migrating every IPC namespace at once if a compat adapter is not in place.

Validation:

- round-trip protocol tests;
- producer tests;
- dispatcher parity tests;
- source guard preventing new stringly producers;
- compatibility tests proving raw legacy requests are accepted.

Expected lift:

- Linux/vmrunner/backend: medium to high.
- SSOT/discoverability: medium.
- General score: small to medium, but real.

### Package 3: Lease, Warm-Pool, And Capacity Ownership

Status: tests-first invariants completed in theyos #137. Deeper ownership
refactor remains backlog unless a concrete bug or invariant gap appears.

Problem:

Typed method names are not enough. The remaining architectural risk is the
lease invariant itself: who creates leases, who counts capacity, who releases,
who reconciles, and what happens when a path fails.

Objective:

- declare one ownership model for lease/warm-pool/capacity behavior;
- centralize invariant checks around that owner;
- add tests for allocation, release, reconcile, orphan cleanup, and counting;
- keep policy unchanged unless explicitly proven and approved.

Likely files:

- theyos `store-rs/src/instance_db.rs`;
- theyos `server-rs/src/capacity.rs`;
- theyos `server-rs/src/reconcile.rs`;
- theyos `server-rs/src/warm_pool_reconciler.rs`;
- theyos executor flow/orchestrator lease cleanup paths;
- vmrunner warm-pool status sources if ownership crosses runner boundary.

Allowed:

- owner facade/module;
- invariant tests;
- additive metadata if byte-compatible;
- cleanup idempotency tests.

Forbidden:

- destructive storage migration;
- deleting real lease rows without a migration plan;
- changing capacity budgets, TTL, release/finalize policy, or schema without a
  reviewed behavior decision.

Validation:

- invariant tests for create/release/reconcile/count;
- warm-pool slot lease tests using `WarmPoolSlotId`;
- no double-release and no silent orphan leaks in tested paths;
- focused Rust crate tests plus CI.

Expected lift:

- Linux/vmrunner/backend: high.
- Mac runner foundation: medium.
- General score: medium.

### Package 4: Mac Runner/VZ Fail-Closed Boundary

Status: closed for the in-process boundary. theyos #138 added the fail-closed
disk gate and panic/lease safety; theyos #146 added the VZ supportability seam
(`VZError::VirtualizationUnsupported`) and #147 gated all 7 macOS-VZ start sites
on `vz::preflight_vz_supportability()`. The live-VM admission path (real
Virtualization.framework boot) remains a human stop-point.

Problem:

Mac runner confidence remains lower because Virtualization/FFI and runtime
limits need a clear trust boundary. Unknown or partial VZ state must not become
best-effort success.

Objective:

- concentrate VZ/FFI boundary behavior in wrappers that return typed errors;
- map limits and unknown states to safe fail-closed outcomes;
- keep lease cleanup and recovery observable.

Likely files:

- theyos `vmrunner-macos-rs` VZ/macOS guest modules;
- `vm_admission.rs`;
- macOS IPC runner binary;
- runner error mapping tests.

Allowed:

- boundary adapters;
- typed error mapping;
- mock/unit tests for nil/error/limit cases;
- fail-closed behavior for unknown VZ states if behavior is locally contained
  and tested.

Forbidden:

- changing live install/provision flow without smoke plan;
- automatic destructive cleanup of uncertain real state;
- touching shipping app.

Validation:

- unit tests for typed errors and admission decisions;
- failure-code mapping tests;
- opt-in live smoke plan before risky live behavior changes merge.

Expected lift:

- Mac runner/macOS engine: high.
- Operational confidence: medium to high.

### Package 5: Live Runner Validation, Opt-In And Reproducible

Status: harness closed; live execution is a human stop-point. theyos #139 added
the opt-in default-skip harness + runbook; #146/#147 added the VZ supportability
preflight that gates admission. Phase-2 live VM-boot validation remains
human-authorized only and is not run in CI.

Problem:

Unit/source tests do not prove VM/VZ, lease, cleanup, and readiness behavior in
the environment where failures matter.

Objective:

- add an opt-in validation path for guest image, VZ/admission, lease
  reserve/release, failed-start cleanup, and readiness;
- keep it reproducible and sanitized;
- do not make heavy VZ E2E mandatory on every PR until stable.

Likely files:

- theyos e2e or vmrunner-macos test harnesses;
- QA runbook/docs;
- runner validation scripts/tests.

Forbidden:

- touching `/Applications/Soyeht.app`;
- logging real machine names, IPs, hostnames, or credentials;
- release/deploy/pin.

Validation:

- opt-in command with neutral logs;
- documented expected artifacts;
- manual/release gate report template.

Expected lift:

- Mac runner/macOS engine: medium.
- Discoverability/operational trust: medium.

### Package 6: Mac Claw Store Guest-Image Readiness Parity

Status: closed. P6/A gating (soyeht-ios #201; theyos #148 admin-create gate);
P6/B reason-coded recovery banner + "Check Again" (soyeht-ios #203); P6/C
mutating "Try Again" / prepare through the shared client (soyeht-ios #204). The
test-only source-guard (soyeht-ios #208) is merged. P6/B is shipped, not a later
product slice.

Problem:

iOS has reason-coded guest-image readiness/recovery behavior. macOS Claw Store
surfaces still lag, so the Mac app can make different install/recovery
decisions from the same engine state.

Objective:

- make macOS Claw Store consume the same readiness/recovery policy as iOS;
- share policy/copy in SoyehtCore where possible;
- keep native UI presentation separate, but not the decision logic.

Likely files:

- `Packages/SoyehtCore` Claw/Bootstrap readiness models and policy;
- `TerminalApp/SoyehtMac/ClawStore/*`;
- macOS Claw Store view model/provider tests;
- docs currently describing guest-image recovery gaps.

Allowed:

- add shared policy helpers;
- add macOS tests for failure codes and action availability;
- route macOS copy/action decisions through shared policy.

Forbidden:

- redesigning the whole Mac UI;
- changing engine protocol without contract fixture coverage;
- touching shipping app;
- adding Product A/nvpn assumptions.

Validation:

- SoyehtCore tests for shared policy;
- focused SoyehtMac tests for Mac Claw Store readiness rendering/action
  behavior;
- source guard preventing raw daemon/VZ error strings from becoming primary UI
  policy;
- privacy and Product A/nvpn scans.

Expected lift:

- macOS app/client: high.
- Cross-platform parity: medium.

### Package 7: Security/Auth Surgical Slice

Status: closed. P7-A PoP gate-completeness guard (theyos #140); P7-B
cross-language PoP/CBOR vectors (theyos #141, soyeht-ios #202); P7-C rate-limit
is DONE and live (theyos #142-145; see Recently Completed). Negative PoP tests
(path / body / timestamp binding, Bearer rejection) are in place. Remaining
backlog is low and not currently actionable: channel/TLS binding is explicitly
future work.

Problem:

PoP/auth is not the current main bottleneck, but concrete gaps should be closed
when they are attached to real backend paths.

Objective:

- wire rate limiting if actual auth-sensitive paths still lack it;
- add negative tests around PoP/path/body/timestamp/caveat if not already
  covered;
- keep PoP format stable unless a separate versioned design is approved.

Likely files:

- theyos household auth/rate-limit modules and tests;
- Swift PoP signer tests if a cross-language fixture is needed.

Allowed:

- narrow rate-limit checks;
- negative tests;
- documentation of channel-binding as future work.

Forbidden:

- changing signing context;
- channel/TLS binding;
- broad CBOR rewrite.

Validation:

- auth rejection tests;
- no Bearer token fallback in household PoP;
- Rust/Swift focused tests only where behavior is touched.

Expected lift:

- Security/auth/PoP: small to medium.

### Package 8: Claw Store Contract Stewardship

Problem:

The Claw Store v1 contract is already relatively mature. Extra fixtures only
raise score when they pin real behavior not already covered.

Objective:

- update contract fixtures only when behavior changes;
- keep Rust, Swift, and React contract tests green;
- defer OpenAPI/codegen until the existing golden contract has stopped
  changing.

Forbidden:

- adding redundant fixtures for score optics;
- normalizing v1 status codes without client evidence;
- broad API client rewrite.

Validation:

- existing Rust/Swift/React contract tests;
- byte-match cross-repo fixture checks.

Expected lift:

- small. This is regression prevention, not the main score engine.

## Backlog After The Main Queue

- Versioned receive-side hardening for IPC owner/kind values. (Human stop-point:
  this rejects previously-accepted wire and needs explicit approval.)
- `WarmPoolSlotId` parser for consumer paths such as orphan cleanup. (Mostly
  satisfied: `capacity.rs`, `instance_create.rs`, and `warm_pool_reconciler.rs`
  consumers already use `WarmPoolSlotId::new(...).owner_id()`; no raw slot-string
  parsing remains, so this is not a current gap unless a new consumer needs to
  decompose IDs.)
- Codegen/OpenAPI/protobuf evaluation after the current golden tests are
  stable.
- Legacy inventory contraction beyond current writer/read guards.
- UI consolidation between iOS and macOS after policy parity is complete.
  (Policy parity is now complete after P6; this is a candidate next objective if
  a fresh architecture-score review approves it.)

## Current Human Stop Points

Do not proceed automatically into these:

- release/deploy/tag/notarization;
- shipping app launch/restart/uninstall/reinstall;
- Product A/nvpn/mesh work;
- destructive ServerStore/PairedMacsStore/SessionStore migration;
- v1 API status code normalization;
- receive-side hardening that rejects unknown previously accepted wire data;
- live VM/VZ smoke on real machines without explicit approval and neutralized
  logs.
