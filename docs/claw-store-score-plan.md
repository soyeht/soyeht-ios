# Claw Store Score-Raising Execution Plan

> Planning document only. This is NOT release authorization and NOT a decision
> to start coding. Execution of any milestone begins only on explicit user GO,
> one bounded reviewer-merged slice at a time.
>
> Companion to `docs/claw-store-architecture-roadmap.md` (the strategic Goals
> A-F and "why the score is low") and `docs/claw-store-execution-plan.md`
> (the P1-P8 slice tracker). This document is the *followable milestone plan*
> from the current verified baseline to a projected final score.
>
> Do not import the experimental mesh / Product A track. Do not validate by
> touching the installed shipping app; Dev builds and explicit gates only.

Last updated: 2026-06-24. Status: EXECUTING v5 - user GO given; @julia orchestrating
@fresh-arch + @code-reviewer slice-by-slice. See §0 for live execution progress.
(v4 history: risk/release-readiness addendum consolidated §4b; Track S1 added.)

## 0. Execution progress (live, 2026-06-24)

User (Caio) gave GO to implement the full plan; @julia commands the agents, each
slice = STOP-POINT -> review -> small PR -> @code-reviewer review -> local merge
(no push). @code-reviewer has caught a real defect in over a dozen of the slices (task-ownership
races, a privacy leak in the QA JSON, a stuck loading flag, a stale service-cache key,
an all-or-nothing catalog/instances poll, a source-blind credential compat init, a
credential-LESS v2 mirror that would erase pairing refs, a stale test fixture, an
unbound lifecycle contract route-set) - all fixed before merge. That hit rate is why
this runs slice-by-slice, not as one drop.

MERGED to local main (23 slices + the GO runbook): all of Track E - E1 (drawer
readiness gate), E1.5 (provider single-flight), E1c (notStarted CTA - 2nd HIGH),
E2a (Store card -> shared MacClawInstallDecision), E2b (Mac install-surface source
guard), E2d-1..4 (pure ClawInventoryService + provider/drawer/Store-VM adoption,
canonical ClawMachineTarget not the lossy ClawAPITarget), E3-mini (Mac
MacActiveServerContextResolver - canonical active-target, off legacy currentContext);
the FULL Track D credential-safety migration - D1 (shadow-compare hardening) -> D2a/
D2b (credential-preserving dedup + live rekeyer, closes the token-orphan) -> D3a
(source guards + dry-run gate) -> D3b (dual-write + gated-read plumbing, credential-
preserving mirror) -> D3c (gated read wired, v2ReadEnabledKey default-OFF); Track F -
F1 (LaunchAgent env SSOT), F2 (Dev embedded-engine smoke), F3.1 (QA matrix runner),
F3.2/F3.3-matrix (Linux + Mac VZ lifecycle rows, opt-in/default-SKIP); Track C4.1
(Swift half of the executable cross-repo contract - 27-route exact pin + lifecycle
DTO decode + all-14-route method/path/auth binding to real client requests). theyos
main: S1-A (engine Tailnet-only in Ready), F3.3 (e2e-rs --guest-os macos), C4.1 Rust
(contract.json + declarative registry + route/wire/cross-check tests). **C4.1 is
COMPLETE cross-repo. Both macOS HIGH bugs closed. The credential migration is
code-complete and gated.**

IN FLIGHT: C4.2a (8 workspaces JSON routes - admin + household GET/POST/PATCH/DELETE,
+ PATCH schema) being built by @fresh-arch Rust-first; @julia does the Swift half on
his hash (same pattern as C4.1).

DEFERRED by design (C4.2 split): C4.2b (attach-token mint + WebSocket PTY attach) -
needs new contract schema (kind: websocket_upgrade, expectations.upgrade {101,
websocket}, admin_stream_auth, household_attach_token header, peer_guard); a separate
reviewable PR after C4.2a, since the token and the WS are semantically coupled.

OPERATIONAL GO (owner's call, never auto-fired): flip ServerStore.v2ReadEnabledKey
after a clean live dry-run. Procedure: docs/serverstore-v2-flip-runbook.md. The gate
is safe-by-construction - loadCanonical serves v2 ONLY if isReadyToFlip && the v2
projection equals v1, else it falls back to v1.

Re-score after the 23 merges: macOS ~7.5-7.8 (both HIGHs closed + the parallel
catalog flows collapsed onto one service + canonical Mac active-target); iOS ~8.4
(E2d + the full D migration + the executable contract); Linux/backend ~8.4 (S1
transport posture + F runner/QA); Mac-runner ~7.9 (F1/F2/F3). Global ~8.0-8.3. The
8.6+ projection now gates only on C4.2 (a in flight, b deferred), the live v2-read
flip, and real F3 guest-boot (per §4b).

Below is the original v1-v4 plan (baseline, tracks, projections) preserved for
reference.

## 1. Purpose and working mode

Goal: move the Claw Store architecture from its current verified baseline toward
the high 8s (9.0 is a stretch, not the expected destination), by executing an
ordered set of bounded slices, each:

- preceded by a read-only inventory + STOP-POINT (report findings before code);
- implemented only after explicit GO;
- reviewed and merged by @code-reviewer as a small PR;
- adversarially verified (claims checked against code before they are trusted);
- re-scored by the architecture reviewers (@fresh-arch / @julia) post-merge.

The plan is the destination; the slices are the steps. We do not stop at
"works, but duplicated" - we follow the tracks until the parallel authorities
and correctness gaps are gone.

## 2. Current verified baseline (origin/main, 2026-06-23)

The big structural Goals already landed (merged 2026-06-21/22): Goal A
release-gating (#188/#109), B1 guest-net constants, B2 vmrunner-common
(#106/#107/#110), B3 route contract pin (#108), C EndpointPolicy SSOT (#187),
plus partial D and C4 fixtures. That is what lifted the global out of the low
7s; the verified global is now 7.6 (was reported 8.0 on an optimistic macOS
assumption - see below).

| Surface | Verified score | Source / confidence |
| --- | ---: | --- |
| iOS client | 8.2 | @fresh-arch, origin/main |
| macOS client | 6.1 | consensus of @fresh-arch + 7-agent adversarial audit + @julia re-audit; range 6.0-6.5 (fresh-arch/audit ~6.1, @julia ~6.5); @julia RATIFIED, no new HIGH |
| Linux/backend runner | 8.3 | @fresh-arch |
| Mac/macOS runner/engine | 7.6 | @fresh-arch |
| Global | 7.6 | @fresh-arch: simple surface mean (8.2+6.1+8.3+7.6)/4 = 7.55 -> 7.6 (7.7 only if backend/contract weighted heavier) |

Note on the global: the earlier 8.0 assumed macOS 7.4. With macOS verified at
6.1 (consensus 6.0-6.5), the honest current global is 7.6. We do not carry 7.8+
as a baseline; it is too high with the macOS client at ~6.1.

### Why macOS is the lowest (verified, file:line)

A 7-agent adversarial audit on origin/main (787ee511), reconciled with @fresh-arch
and @julia, confirmed and ALSO refuted claims, landing macOS at ~6.1:

Real correctness gaps (not just duplication):

- HIGH (product bug, NOT unsafe): the main-window drawer
  (`ClawDrawerViewController.swift:710-721,147-174`) offers and POSTs
  `installClaw` with NO guest-image readiness gate, while both Store surfaces
  enforce it (`MacClawStoreRootView.swift:261`). A user can issue an install the
  Store would block. The backend has a backstop (`instance_create.rs` -> 409
  GUEST_IMAGE_NOT_READY) and the drawer surfaces the error, so it is not a
  data-safety hole - but the user gets a raw backend error instead of the
  `MacGuestImageRecoveryBanner` the Store shows. Secondary surface, real bug.
- MEDIUM: the drawer drops install-completion polling (`:163-173`) - clears
  progress on POST-accept and relies on a single `refresh()`, not the Store's 2s
  poll-to-terminal loop; reports "installed" before the backend finishes.
- LOW (downgraded by @julia; original evidence was stale): `InstalledClawsProvider`.
  The deferred-Task clearing the audit cited was already REMOVED in 787ee511
  (`:80-89` is now a synchronous MainActor clear; the sequential collapse is
  fixed). Residual: no identity guard on cancel/replace (server switch at
  `:53-55`) and no `guard !Task.isCancelled` before writing `self.claws` (`:108`)
  - at most one redundant concurrent fetch + last-writer-wins, no corruption.

Duplication / coupling:

- No shared Core domain service: 3 catalog-fetch flows + 5 getInstances sites,
  each rolling its own fetch/cache/online-filter; the "show Install" rule is
  derived independently in 3 places (`MacClawCardView.swift:62-64` inline,
  `ClawDrawerViewController.swift:710-721`, shared `ClawDetailActionAvailability`).
- ~4 competing target authorities (ServerStore v1 + SessionStore.pairedServers +
  activeServerId + PairedMacsStore), divergent kind taxonomies, no iOS-style
  resolver on Mac.

What keeps macOS OFF a 5.x floor (refuted by the audit, reinforced by @julia):

- Target/auth/endpoint boundary is CLEAN: no `ClawAPITarget.household` construction
  in the Mac ClawStore tree, no raw `URLRequest`/header/`https://`/`URL(string:)`;
  everything goes through `apiClient` + `context`/`machineTarget`. Even the drawer
  honors the backend installability gate (theyos #88) - what is missing is
  specifically the CLIENT-side guest-image gate.
- The dedicated Store window cleanly reuses the shared Core view models.
- `ServerStoreV2` is dead/shadow-only (zero non-test callers).
- No force-unwrap crashes, timer leaks, or retain cycles.

## 3. Target and projected final score

Target: global high 8s (8.6-8.8), with no surface below ~8. 8.9 is possible only
if Track F and C4 are genuinely executable gates (not fixtures/runbooks); 9.0 is
a stretch, not the central projection.

Projected final, if the full plan executes (numbers reviewed and approved by
@fresh-arch):

| Surface | Now | After plan | Main driver(s) |
| --- | ---: | ---: | --- |
| iOS client | 8.2 | 8.8-9.0 | Track D (live ServerStore SSOT) + shared Claw services + householdEndpoint capability test |
| macOS client | 6.1 | 8.0-8.3 | Track E (drawer parity + shared services + Mac resolver) PLUS D + F (E alone reaches only ~7.5-7.8) |
| Linux/backend runner | 8.3 | 8.5-8.7 | Track F real QA matrix (or an explicit lease/capacity ownership slice) |
| Mac runner/engine | 7.6 | 8.3-8.5 | Track F (LaunchAgent env SSOT + embedded-engine smoke) |
| Global | 7.6 | 8.6-8.8 | single-authority + executable validation; 8.9 stretch, 9.0 not central |

These are estimates, not guarantees; each milestone re-scores post-merge and the
projection is corrected from real movement.

### Cross-track dependencies for the final targets (important)

The per-surface finals are NOT single-track; @fresh-arch flagged real coupling:

- iOS 8.8-9.0 does not come from D alone. It also needs part of Track E (shared
  services so iOS and macOS share install/catalog semantics) and resolving
  `householdEndpoint` resource-options/users, or making capability/unsupported
  behavior explicit with a test. The real "installed on which servers" aggregate
  / live metadata is polish that helps reach 9, not a blocker for 8.8.
- macOS 8.0-8.3 does not come from E1-E3 alone (those reach ~7.5-7.8). Reaching
  8+ needs Track D (live target/inventory) and Track F/QA proving
  Store/drawer/provider/setup in real runtime.
- Linux 8.7 needs F3 to be a REAL reproducible Dev matrix with full Claw
  lifecycle, OR an explicit lease/capacity ownership slice if the inventory shows
  real duplication in `capacity` / `reconcile` / `warm_pool` / `instance_db`. Do
  not assume a checklist-only F3 lifts everything.

## 4. The plan (ordered tracks and milestones)

Priority order: Track E first (lowest score + a real bug), then D (largest
global leverage), then F (runner/engine + backend confidence), with C4-full
coupled to F.

### Track E - macOS client toward ~7.5-7.8 on its own (from 6.1)

- E1. Drawer readiness + lifecycle parity.
  - Close the HIGH correctness gap: the drawer must require
    `readiness.state.allowsInstall` before showing/issuing install, surface the
    same `MacGuestImageRecoveryBanner`, and stop diverging on install lifecycle
    (align polling/notification semantics with `ClawStoreViewModel`).
  - Files: `TerminalApp/SoyehtMac/ClawStore/ClawDrawerViewController.swift`,
    `MacClawStoreRootView.swift`, `MacGuestImageReadinessGate.swift`.
  - Acceptance: drawer cannot POST `installClaw` when readiness blocks; tests in
    `SoyehtMacTests` prove blocked-readiness does not call install and allowed
    does; behavior (not string) assertions; no wire change.
  - Score delta: macOS -> ~6.4-6.5 if it is only a button gate; ~6.6-6.8 if it
    includes the full readiness + lifecycle/polling/notification alignment.
- E1.5. `InstalledClawsProvider` single-flight fix (LOW).
  - Add a ~5-line identity/cancel guard (check loadTask is the current task
    before niling it; and a `guard !Task.isCancelled` before writing `self.claws`)
    so a cancelled task's `defer` cannot nil a newer task's slot. Do NOT invest
    beyond that. Closes alongside E1.
  - Score delta: small correctness; folds into the E track.
- E2. Shared Core Claw services.
  - Extract `ClawCatalogService` / `InstalledClawsService` (and align
    `ClawInstanceService`) in SoyehtCore; make Store root, drawer, and
    `InstalledClawsProvider` consume one fetch/cache/online-filter/policy path.
    To earn the score it must actually KILL the parallel Store/drawer/provider
    flows, not just extract wrappers.
  - Acceptance: one catalog/instances authority; drawer and Store share install
    semantics; `.unavailable` guard lives in one place. PLUS (per @julia) a
    Mac-tree SOURCE GUARD - extend `ClawRouteUsageTests` (today it scans only the
    iOS `Soyeht` tree) to `SoyehtMac`, running as a real `SoyehtMacTests` target
    test (not an iOS-side string scan), proving ALL Mac install surfaces consult
    the shared availability/readiness policy, so a future surface cannot
    reintroduce the bug #1 class. Also normalize `ClawInstallState.isInstalled`
    treating `.uninstalling` as installed (`ClawModels.swift:249-252`), which
    currently leaks into `ClawDetailActionAvailability.swift:91` and
    `InstalledClawsProvider.swift:106`.
  - Score delta: macOS -> ~7.3-7.8; iOS +0.1 to +0.2.
- E3. Mac Claw target resolver (depends on Track D more than it looks).
  - A macOS equivalent of `ClawInstallTargetResolver` so setup/provider/drawer
    stop choosing target from ~4 competing sources. Needs D's live inventory to
    resolve target/inventory rather than wrap the legacy stores.

### Track D - inventory SSOT, lifts iOS + macOS (from 8.2)

- D-full. `ServerStoreV2` as the LIVE authority.
  - Flip ServerStore v2 from shadow to live writer; id-preserving migration;
    `ServerRegistry` becomes a read-only facade; `PairedMacsStore` /
    `SessionStore.pairedServers` become ingestion/credential adapters; source
    guards stop new UI from enumerating legacy stores; shadow-compare before the
    flip.
  - Acceptance per the roadmap Goal D acceptance list (shadow parity, Server.ID
    preserved, Mac/Linux/duplicate/missing-token/stale-alias/unknown-kind tests,
    rollback safe).
  - Score delta: iOS +0.5 to +0.7 (-> 8.7-8.9); macOS +0.2 to +0.4; global +0.3
    to +0.5. D does not raise the runner and only partially lifts macOS.

### Track F - runner/engine + backend QA (from 7.6 / 8.3)

- F1. LaunchAgent env SSOT spec.
  - Make a testable `EmbeddedEngineLaunchAgentSpec` for release/dev and generate
    or fully validate the `com.soyeht.engine{,.dev}.plist` runtime env against
    it, so `SoyehtInstallProfile` (already SSOT for names/ports/logs) extends to
    the full runtime environment. No behavior change, no shipping-app touch.
  - Independent of E/D; can run in parallel if a separate slice, but must not
    delay E1.
  - Score delta: Mac runner +0.3 to +0.5.
- F2. Dev embedded-engine smoke (opt-in).
  - App bundle Dev installs the engine in the Dev namespace, registers/kickstarts
    only the Dev LaunchAgent, queries health/bootstrap/status, verifies helper
    discovery. Inert by default in CI when VZ/SMAppService is unavailable.
  - Score delta: Mac runner +0.2 to +0.3; backend confidence.
- F3. Backend QA matrix (must be a REAL reproducible Dev matrix, not a checklist).
  - Reproducible Dev matrix with full Claw lifecycle: Mac engine mobile path, Mac
    household path, Linux admin-host path, iOS client, macOS client -
    catalog/availability/install/deploy-status/attach/uninstall/auth-failure/
    unsupported-capability.
  - Score delta: Linux +0.2 to +0.4; Mac runner +0.2 to +0.3; global confidence.

### Track C4-full - executable cross-repo contract (coupled to F)

- Swift generates expected requests + decodes responses; Rust asserts routers
  match the same fixtures; CI fails on route/method/auth/DTO/error drift. Must
  cover create/status/actions/workspaces/attach/auth-failures and run alongside
  the QA matrix. Alone ~+0.1-0.2 global since the v1 contract is mature.

### Track S1 - household transport posture (NEW, from @fresh-arch backend audit)

- S1. Ready-state transport hardening. The `8091` control plane in Ready binds
  LAN + Tailscale over plain HTTP, not mesh-only, while the design doc requires
  TLS even on LAN - a documented requirement not implemented. Choose Tailnet-only
  in Ready OR TLS + replay-cache for LAN, with tests + docs. PoP/caveats are good
  today; this closes the documented-vs-implemented gap before we sell a
  release-ready posture.
  - Severity: MED-HIGH. Gating for the 8.6+ projection / release-readiness, NOT
    for starting E1.

## 4b. Risk / release-readiness addendum (consolidated 2026-06-23)

Consolidated by @julia after @bianca's pane closed, joining the client audit
(@julia, 7-dimension adversarially-verified workflow) and the backend audit
(@fresh-arch). Read-only; nothing implemented. The full per-item client table
(`ABERTO?(file:line) | severity | in-plan?`) was delivered in-thread; the
headlines that change the plan:

Client (macOS/iOS), NOT in plan v3:

- HIGH **2a (CONFIRMED)**: macOS `.notStarted` guest-image has no reachable
  mutating "Prepare this Mac" CTA -> a never-prepared Mac is a permanent dead-end.
  `GuestImageRecoveryPolicy.swift:82-90` collapses `.notStarted`+`.inProgress`
  into `cta:.none`; `MacGuestImageRecovery.swift:76-93` hard-codes `.checkAgain`.
  Severity decider RESOLVED by @fresh-arch against theyos 7aa7361: the engine does
  NOT auto-start prep on `GET /bootstrap/status` (`handlers_bootstrap.rs:444-461`
  read-only; mutating start only on `POST .../guest-image/prepare`,
  `handlers_household_guest_image.rs:314-361`). No auto-start rescues it -> HIGH
  stands. Folds into E1 (or an E1-adjacent prepare-CTA slice).
- HIGH/PARTIAL **4a + 4c**: Track-D Mac dedup can orphan the session token
  (`ServerStore.swift:288` drops loser row with no token re-key; merge `:297-330`
  prefers the pairing-secret owner, not the session-token owner); the shadow
  comparer (`ServerStoreShadowComparer.swift:104-152`, single `hasCredential`
  Bool) can't detect it -> false-clean pre-flip gate. Plan lists "missing-token"
  but no rule preserves the loser's token through collapse. -> Track D acceptance.
- HIGH (conditional) **4b**: no persisted v1 rollback after the V2 flip
  (`ServerStoreV2Migrator` only projects, never writes back). -> Track D acceptance
  must add dual-write OR an explicit "no rollback after flip" gate.
- MED **3a**: `AppEnvironment.defaultContainer` process-wide cache never
  invalidated on server switch -> quick-start can attach a terminal to the wrong
  server. Outside every guard. -> E2/E3.
- MED **i18n (1e+6b+6c)**: referenced-but-absent keys + inline
  `LocalizedStringResource(defaultValue:)` ship English for every locale, bypassing
  the 17-language gate; no "referenced-key-exists" test exists. -> E2 + a catalog guard.
- MED **7d (meta-gap)**: macOS (lowest score) is the LEAST testable - SoyehtMacTests
  symlinks only the AppKit-free domain; drawer/cards/views are structurally
  untestable, so E1/E2's "tests in SoyehtMacTests prove ..." is unreachable as
  written without extracting derivations to the AppKit-free domain. -> E1/E2
  acceptance feasibility.
- Source guards (`ClawRouteUsageTests`/`LegacyBoundaryUsageTests`) scan only
  `TerminalApp/Soyeht`; the Mac guard must be a NEW invariant test (E2), not a
  rename. `.uninstalling`-as-installed leaks into 5+ more sites than the 2 named.

Backend (@fresh-arch, theyos 7aa7361), NOT in plan v3:

- S1 transport posture (above): MED-HIGH -> new Track S1.
- Version/capability gate: engine exposes version, but mutating Claw actions don't
  check capability/version; `runtime_min_version` in the artifact manifest is dead
  without enforcement. MED -> new track or C4/F3-hardening.
- Artifact provenance: `latest.json` is movable/unsigned and the manifest accepts
  `http://`; the payload hash is verified but the hash comes from the manifest
  itself. MED -> hardening.
- Guest-boot validation: VZ/Firecracker live boot/SSH is opt-in/default-skip; F3
  needs explicit acceptance of real rebuild/boot/SSH/golden, not a checklist.
- Create/lease rollback: `resource_leases` ownership is SSOT + invariant-guarded
  (better than feared), but rollback via IPC on create failure is
  warn-and-continue; the reaper mitigates runtime, a storage leak can remain. MED
  operational -> F3.
- Lease/capacity ownership (general): LOW-MED; keep as F3 acceptance, no own track.
- Bonjour Ready metadata publishes identifiers/version on non-loopback; likely
  intentional but needs a threat-model/privacy acceptance in F3/S1.

Release-readiness framing (@fresh-arch, agreed): **E1 can start now; the global
8.6+ projection is conditioned on S1 transport posture, the version/capability
gate, and F3 real guest-boot. Without those, 8.6 is an optimistic ceiling, not a
release-readiness baseline.** None of these block E1 - a localized client slice
that closes a real bug independent of S1/D/F.

## 5. Per-milestone score projection (running, @fresh-arch-reviewed)

| After | iOS | macOS | Linux | Mac-runner | Global |
| --- | ---: | ---: | ---: | ---: | ---: |
| (baseline) | 8.2 | 6.1 | 8.3 | 7.6 | 7.6 |
| E1 (+E1.5) | 8.2 | 6.4-6.8 | 8.3 | 7.6 | ~7.7 |
| E2 (+E3) | 8.3 | 7.3-7.8 | 8.3 | 7.6 | 7.9-8.1 |
| D-full | 8.7-8.9 | 7.6-8.0 | 8.3 | 7.6 | 8.2-8.4 |
| F1-F3 | 8.8 | 7.8-8.2 | 8.5-8.7 | 8.3-8.5 | 8.4-8.6 |
| C4-full | 8.8-9.0 | 8.0-8.3 | 8.5-8.7 | 8.3-8.5 | 8.6-8.8 |

(8.8 global only if E/D land at the top of their ranges and F is a reliable gate,
not opt-in only; 8.9 stretch; 9.0 not the central projection.)

## 6. Sequencing and dependencies

1. E1 -> E1.5 first (closes the real bug + the LOW single-flight; smallest blast
   radius).
2. Then E2 and D-full in parallel or very close - E3 depends on D's live
   inventory more than it looks, so do not start E3 before D is moving.
3. F1 is independent and can run in parallel as a separate slice, but must NOT
   delay E1.
4. F2 -> F3 after F1. C4-full after F3 or alongside any contract change.

Recommended first slice: E1 (closes the one real product bug, smallest blast
radius, no wire change, no cross-dependency).

## 7. Risks, freeze rules, out of scope

- Freeze: no new endpoint resolvers / host classifiers / route builders / one-off
  transport helpers; no new Store UI surface before shared services exist; no
  experimental mesh assumptions; no shipping-app validation.
- Migration risk (Track D): additive migration, shadow compare, preserve
  Server.ID, readable rollback - or machine IDs/aliases/credentials can
  duplicate or disappear.
- Out of scope: Product A / nvpn / mesh; release/sign/notarize/pin; live VZ/VM
  promotion; destructive storage migration; rejecting previously-accepted wire
  without a compat plan.

## 8. Reviewer ratification status

- @fresh-arch: plan APPROVED (global baseline 7.6; final 8.6-8.8 central, 8.9
  stretch, 9.0 not central).
- @julia: macOS baseline RATIFIED on origin/main (she lands ~6.5, within the
  6.0-6.5 consensus; no new HIGH). Refinements folded in: bug #1 is a HIGH product
  bug with a backend 409 backstop (not unsafe); bug #3 downgraded to LOW with
  updated evidence; new E2 acceptance = Mac-tree source guard; `.uninstalling`
  isInstalled normalization added to E2.
- Both reviewers agree: E1 first, order E -> D -> F. Plan ready for user
  direction GO.
- @code-reviewer (2026-06-23): plan v3 is actionable for E1 as a direction; no
  blocker before GO for a read-only inventory. E1 is NOT direct implementation
  yet - it needs a short STOP-POINT (confirm drawer shape, the readiness gate to
  reuse, shared/mirrored lifecycle/polling, minimal tests) before the small PR. If
  the STOP-POINT reveals E1 needs a larger shared-service, @julia stops and
  reports rather than coding.
- @fresh-arch (2026-06-23): plan ready for GO on E1; nothing in the backend audit
  blocks E1 (localized client slice, independent of S1/D/F). Confirmed against
  theyos 7aa7361 that the engine does NOT auto-start guest-image prep on
  `GET /bootstrap/status` -> client finding 2a stays HIGH. Backend findings folded
  into §4b + new Track S1. The 8.6+ projection is conditioned on S1 + the
  version/capability gate + F3 real guest-boot.
- @bianca: pane closed mid-coordination (froze); the "Risk/release-readiness"
  consolidation she owned was picked up by @julia (§4b). No content lost - both
  audits were re-sourced from @julia's thread and @fresh-arch live.

## 9. Change log

- 2026-06-23 v4 (DRAFT): consolidated the Risk / release-readiness addendum (§4b)
  from @julia's client audit (7-dimension adversarially-verified workflow) +
  @fresh-arch's backend audit; added Track S1 (household transport posture).
  @fresh-arch resolved client finding 2a's severity decider against theyos 7aa7361
  (no engine auto-start of guest-image prep on `GET /bootstrap/status`) -> 2a is
  CONFIRMED HIGH. @code-reviewer + @fresh-arch both signed off that E1 is unblocked
  and ready for the user's GO (E1 via a STOP-POINT-gated read-only inventory, not
  direct implementation). @julia took over the consolidation after @bianca's pane
  closed. No code, no execution - still awaiting the user's GO.
- 2026-06-23 v3 (DRAFT): @julia ratified macOS baseline on origin/main (~6.5,
  within the 6.0-6.5 consensus; no new HIGH). bug #1 reframed (HIGH product bug,
  backend 409 backstop, not unsafe); bug #3 downgraded MED->LOW with updated
  evidence (deferred-Task clear already removed; residual is the missing identity
  guard); E1.5 marked LOW (~5-line guard); E2 acceptance hardened with a Mac-tree
  source guard (`ClawRouteUsageTests` extended to `SoyehtMac`) + `.uninstalling`
  isInstalled normalization. @fresh-arch had approved v2.
- 2026-06-23 v2 (DRAFT): @fresh-arch reviewed the projections. Corrected global
  baseline 7.6 (was ~7.7-7.8); tightened per-milestone and final ranges (macOS
  final 8.0-8.3, Mac-runner 8.3-8.5, global 8.6-8.8); 9.0 reframed as stretch;
  added cross-track dependencies; sequencing nuance (E2 and D near-parallel, E3
  depends on D, F1 must not delay E1).
- 2026-06-23 v1 (DRAFT): initial plan from the post-#187/#188 verified baseline;
  macOS 6.1 reconciliation (fresh-arch 7.4 + julia 5.5-on-stale-base resolved by
  adversarial audit). Pending @julia re-audit and user direction GO.
