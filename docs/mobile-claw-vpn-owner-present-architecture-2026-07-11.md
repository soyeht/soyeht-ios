# Mobile Claw VPN Owner-Present Architecture Decision - 2026-07-11

> **Reference:** Product A owner-present architecture decision, 2026-07-11
>
> **Status:** Accepted architecture direction; pre-implementation; no activation
> approval.
>
> When referring to this decision, use: **"the 2026-07-11 Product A
> owner-present architecture decision."**

## Decision Summary

Product A will use a hybrid, effect-centered security boundary.

The repo-wide PRE-EFFECT scanner is not the security authority. It may remain a
small auxiliary tripwire, but a green scanner result does not prove that the
owner-present effect is absent or safe.

The authoritative controls are:

1. The local tunnel capability is absent from production Apple artifacts until
   explicit activation.
2. The server-side owner-present effect has no production route or issuer before
   activation.
3. Phase 1 implements one private server mutation sink that accepts only a
   fresh, server-produced, single-use capability bound to the exact operation;
   production activation remains a later human gate.
4. Release provenance covers the complete shipped product and all external
   native inputs.
5. Activation remains an explicit human gate. This document is not that gate.

## Why The Scanner-Authority Design Was Retired

PR #296 attempted to prove safety by scanning the source repository for every
possible owner-present crossing. Repeated reviews found structurally different
bypasses, including:

- alternate package and build manifests;
- generated code, plugins, macros, and build scripts;
- data-driven dispatch and interpreted resources;
- dynamically loaded code;
- app extensions, embedded helpers, nested apps, and packaged archives;
- the embedded `theyos-engine` binary;
- `RelayStreamGuestFFI.xcframework` and Rust dependencies built outside the iOS
  Git object database;
- post-build and post-link mutations.

The problem is open-ended: a scanner can recognize known signals but cannot
prove semantic absence across every possible source, build, packaging, and
runtime representation.

The useful work from #296 is retained where applicable: contracts, fixtures,
goldens, pins, negative tests, and semantic documentation. The large scanner and
repo-wide baselines are not retained as an authority.

## Two Independent Effects

The architecture treats the local and server effects separately.

### E_local: Local System Tunnel

`E_local` is the ability of an Apple product to install or run the system VPN
tunnel.

Before activation, the signed production artifact must have:

- no Network Extension or VPN entitlement;
- no packet-tunnel or equivalent provider extension point;
- no linked or embedded local tunnel implementation accepted by the policy;
- no unclassified shipping binary or nested executable container.

This is an OS-enforced backstop for the local tunnel. It does not prove that the
client cannot call a server API.

### E_server: Server-Side Owner-Present Mutation

`E_server` includes minting an owner-present offer, session, configuration, or
Mesh state delta.

The absence of an Apple entitlement does not protect `E_server`. Its authority
must live at the server's unique effect sink.

## Phase 0: PRE-ACTIVATION

The production system is closed before activation:

- owner-present routes and issuers are compiled out of the production server;
- the embedded production `theyos-engine` also excludes those routes and
  issuers;
- the iOS production artifact has no local tunnel capability;
- no client, normal mint API, admin API, IPC path, or store helper can produce
  the equivalent owner-present mode or Mesh effect;
- external artifacts are pinned and carry producer-side provenance;
- the scanner, if retained, reports suspicious references only as an auxiliary
  warning.

No runtime configuration flag may silently turn Phase 0 into Phase 1.

## Historical V1 Wire Status

`owner_present_success_wire_v1` is retained only as immutable, test-only
evidence from the PRE-EFFECT contract work. It is not an implementation
authority for Phase 1. In particular, its client-carried `proof_token` and
separate proof-bearing mint request are superseded by this decision and must
never be wired into a production client or server.

Phase 1 must first land a new versioned wire contract in which finish,
capability consumption, and mint remain server-side. The client may receive a
non-authoritative operation handle or count-only status, but no bearer value
whose possession authorizes mint. Until that replacement contract is reviewed
and landed, the historical V1 vectors are useful only for interoperability,
decoder, and negative-regression tests.

## Phase 1: Owner-Present Implementation

Phase 1 implementation and review proceed after Phase 0 without enabling the
production route or Apple capability. The minimum accepted shape is:

1. The server creates a fresh, random WebAuthn challenge independent of any
   context digest.
2. In one authoritative state record, the server atomically associates that
   challenge and its identifier with the exact canonical reviewed context,
   including member, device, Claw, operation, nonce, configuration generation,
   authority state, expiry, and approved release artifact identity. Finish must
   require the stored, submitted, and reconstructed context bytes to be
   identical; the challenge itself is not the context commitment.
3. The trusted RP renders the canonical operation summary. Native UI is not the
   authority for WYSIWYS.
4. Successful verification produces `VerifiedOwnerPresence` inside the server.
5. A private server capability is minted from that verified presence. It is
   opaque, non-forgeable, bounded, single-use, and preferably never sent to the
   mobile client.
6. The unique mutation sink consumes the capability by value. No normal mint,
   admin, IPC, or alternate store path can produce the same effect without it.
7. Consumption or tombstoning is irreversible before mutable revalidation.
8. Under the authoritative lock or transaction, the server rechecks dual-clock
   expiry, household membership, device and Claw binding, the triplet ACL,
   `member_devices`, availability, revocation, configuration generation, and
   current authority state immediately before the Mesh effect.
9. Any mismatch, timeout, panic, restart ambiguity, or downstream failure burns
   the capability and produces zero unauthorized Mesh delta.
10. The mobile client receives only a datapath credential bound to the device,
    grant, target, expiry, and revocation state. It never receives authority to
    mint the owner-present capability.

The admission path must reconsult server-held state when opening the datapath.
Where the protocol supports a long-lived session, revocation must also be
enforced during the session. The existing `claw_share` slot, proof-of-possession,
target-binding, replay, and revocation model is the reference behavior to reuse.

## Failure And Recovery Semantics

- A capability is at most once, not retryable after an ambiguous effect.
- Response loss does not recreate or refund a capability.
- Replay and concurrent consumption result in exactly one possible winner.
- Crash recovery uses a journal, idempotency record, or count-only
  reconciliation. It never retries the mutation blindly.
- Missing RP state, missing configuration, store exhaustion, clock regression,
  restart, or unavailable authority fails closed.

## Release Provenance And Artifact Attestation

Security claims must be made about the final bytes delivered to users, not only
the source tree or an intermediate archive.

The release pipeline must:

1. Build from one exact source commit in a clean, network-denied environment
   after declared inputs are fetched and verified.
2. Pin the Xcode, SDK, Swift, Clang, Rust, UniFFI, build-action, plugin, macro,
   script, package, and crate inputs used by the build.
3. Treat code generation and resource generation as declared, hashed inputs.
4. Recursively inventory the final IPA, app, DMG, and update payload after every
   packaging mutation.
5. Include every app, `.appex`, framework, XPC service, helper, nested app,
   executable, archive, resource consumed as code or policy, symlink target, and
   Mach-O slice.
6. Treat `theyos-engine`, `RelayStreamGuestFFI.xcframework`, `household-rs`, other
   first-party Git crates, Sparkle, its feed and signing key, nested DMGs, and the
   uninstaller as first-class provenance entries. Commit the macOS project's
   resolved Sparkle revision and record that exact revision in every release
   attestation.
7. Require producer-side attestations for external binaries. A checksum proves
   identity, not benign behavior.
8. Emit a canonical closure manifest, SBOM, and signed provenance binding the
   source, dependencies, toolchains, policy state, and final published digest.
9. Verify the publicly downloaded artifact, not only the local build output.

Code signing and notarization prove origin and integrity. They do not prove the
absence of an owner-present effect, so they are necessary but not sufficient.

## Human Activation Gate

The owner-controlled gate must remain explicit and auditable.

Activation requires separate approval for:

- requesting or enabling the Apple tunnel capability;
- shipping the server route and issuer;
- allowing a release artifact digest to participate in owner-present flows;
- enabling the trusted RP and credential policy;
- wiring the unique effect sink and datapath admission checks.

No environment variable, remote payload, Sparkle update, or ordinary server
configuration change may bypass this gate.

## Measurable Controls

The implementation and release reviews must be able to demonstrate:

- zero owner-present route or issuer in Phase 0 production server and engine;
- zero local tunnel entitlement or provider in Phase 0 signed Apple products;
- complete classification and hashing of the final shipping closure;
- 100 percent pin and provenance coverage for external executable inputs;
- exactly one private server effect sink;
- zero effect from unknown, wrong-member, wrong-device, wrong-Claw, stale,
  replayed, expired, revoked, or concurrently reused authorization;
- exactly-once consumption under concurrency;
- server-held revocation checked at datapath admission and during the session;
- negative release tests that intentionally add a forbidden route, entitlement,
  provider, binary, resource, dependency revision, or alternate sink and require
  the gate to fail;
- an auditable server ledger for approval, capability issuance, consumption,
  burn, and rejection, without logging secret values.

## Residual Risk

This architecture reduces the trusted computing base but does not eliminate all
risk. Remaining risks include compromise of the server, CI, compiler, signing
key, owner credential, Apple platform, or a reviewed dependency; social
engineering during owner approval; and an authorized but compromised device
acting within its own valid, unrevoked grant.

Eliminating the last endpoint risk would require the server to terminate the
entire effect and return only a result, which is a different product design.

## Implementation Order

1. Preserve the useful #296 contracts, fixtures, tests, documentation, and pins.
2. Retire #296 as a security authority; optionally keep a small tripwire with an
   explicit sunset and no activation authority.
3. Define and review the exact local and server effect inventories.
4. Land Phase 0 compile-out checks and final-artifact provenance.
5. Reuse and generalize the existing server-held `claw_share` admission model.
6. Implement the unique capability-only owner-present effect sink.
7. Add the trusted RP flow and server-side WYSIWYS binding.
8. Add the client control plane without exposing the server mint capability.
9. Run failure, replay, concurrency, revocation, crash, and artifact mutation
   tests.
10. Request a separate human activation decision. No prior review GO transfers
    to that decision.

## Continuous Execution Policy

Phase boundaries are engineering and review gates, not mandatory pauses for
user input.

After the user resumes the implementation goal with this architecture as its
scope, agents should continue autonomously through Phase 0, Phase 1, client
integration, and sanitized DEV E2E readiness. They should create bounded PRs,
run CI, obtain SHA-bound reviews, fix findings, merge approved slices, and begin
the next safe slice without waiting for another user message.

Agents must not remain idle while a safe, reversible task from the
implementation order is available. A failed review or CI job starts a fix and
re-review loop; it does not by itself require a human decision.

Human confirmation is required only before an irreversible or external action:

- requesting or enabling the Apple Network Extension entitlement;
- enabling the production owner-present route or issuer;
- using production secrets, private infrastructure, physical devices, or
  owner-present sudo interaction;
- publishing or activating a production release;
- changing the signed definition of the effective security boundary.

At those gates, agents provide the evidence accumulated so far and wait for an
explicit activation decision. The software implementation should otherwise
continue until it is complete and DEV-E2E-ready.

## Review And Goal Resume Rule

This decision does not automatically resume any blocked agent goal. Once the
user resumes the implementation objective, completion of Phase 0 does not pause
that active goal or require another message.

All future reviews start from the exact new SHA with no automatic GO transfer
from #296 or from this architecture discussion.
