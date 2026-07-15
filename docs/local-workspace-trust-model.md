# Local Workspace Trust Model

Status as of 2026-06-29: product direction approved; US-13 schema/vectors and
the pair-machine gate are staged, but Local Workspace promotion still waits on
strong-tier minting and the remaining fan-out gates.

## Product Principle

Local assurance scales with blast radius.

- A single Mac can create and use a local workspace on that Mac.
- Adding another device, remote access, mesh, relay, or VPN increases blast
  radius and requires a server-verifiable strong owner approval path.
- The approved strong-owner direction is Secure/Upgrade with iPhone, once the
  strong-tier minting STOP is resolved.

User-facing language should frame this as:

- "Neste Mac" / "Local Workspace" for Mac-only use.
- "Secure with iPhone" or "Approve with iPhone" before connecting other
  devices.

It must not claim that a Mac-only owner is hardware-attested or equivalent to
the iPhone owner.

## User Stories

### US-1: Mac Local Workspace

The user opens Soyeht on a Mac and creates a local workspace without a phone.
This mode is local-only:

- local terminal/workspace use is allowed;
- no pair-machine fan-out;
- no mesh/relay/VPN membership;
- no remote attach;
- no "verified hardware" or "attested owner" badge.

Current backend behavior supports the most important boundary: a Mac founder
without `owner_auth` cannot stage pair-machine fan-out because the engine
requires `current_owner_auth()` and rejects with `owner_not_paired`.

### US-2: Mac Plus iPhone

The user starts on Mac, then secures the workspace with an iPhone owner. The
desired experience is:

1. Mac asks to secure/connect.
2. iPhone reviews and approves with biometric owner approval.
3. Mac receives an approved/online state.
4. Connectivity can then choose the best available path.

The iPhone approval ceremony is the trust transition. The Mac should never show
technical copy such as "attestation failed" to the user.

The exact "approved/online" signal is still an open protocol/product decision.
Today the Mac learns authenticated presence/reactive connectivity. A future
Apple-level experience may need an explicit approved/denied signal rather than
relying only on presence reconnection.

Current wire evidence:

- `PresenceProtocol.swift` defines `presence_ready` and `presence_denied`, but
  no `presence_approved` message.
- `PresenceSession` sends `presence_ready` only after the presence HMAC verifies.
- `MacPresenceClient` maps `presence_ready` to `.authenticated`, which the iPhone
  UI renders as "online".

That means the current online state is reactive connectivity, not an explicit
approval event. Before promising an immediate Apple-level handoff,
choose one of these protocol directions:

- **Reactive-only:** keep the current model. The Mac becomes "online" only when
  the iPhone reconnects and authenticates presence. This is simpler but cannot
  honestly guarantee an immediate approved state after the iPhone review.
- **Explicit approval signal:** add a reviewed `presence_approved` /
  `approval_denied` or server-to-Mac event that the Mac receives after the owner
  approval/strong-tier ceremony. This supports immediate UX, but needs a
  versioned wire contract, replay protection, tests on both sides, and a clear
  distinction from mere network presence.

Do not add this wire message opportunistically inside the strong-tier minting
slice. It is the UX/protocol half of Secure/Upgrade with iPhone and needs its
own reviewed contract. The decision brief lives in
`theyos/docs/followup-approved-online-signal.md`.

### US-3: Multi-Machine

Mac-to-Linux, Linux-to-Mac, relay, mesh, VPN, and remote attach are all
post-trust capabilities. They require an approved owner and must not be
available from a local-only Mac founder by themselves.

Connectivity selection is a transport concern:

1. direct/LAN when available;
2. relay/community relay when appropriate;
3. VPN/mesh when explicitly integrated and owner-approved.

These transports carry traffic between devices that are already approved. They
do not replace owner approval and do not establish authority.

### Future: Android

Android can become a future owner platform only through its own reviewed trust
model. It is not part of the current iPhone-owner path.

## Current Gap

The current model is partially enforced:

- Good: no `owner_auth` means no pair-machine fan-out.
- Good: `PersonCert` now has signed `owner_auth_tier` / `owner_provenance`
  fields with cross-language vectors. Missing, tier-less, legacy, unknown,
  malformed, or null values are non-strong by construction.
- Good: App-Attest-specific provenance names are schema-staged and
  cross-language-vector pinned, without adding runtime App Attest minting.
- Good: Secure/Upgrade transcript bytes are cross-language-vector pinned before
  any verifier or minter depends on them.
- Good: pair-machine approval now checks the strong-tier classifier only behind
  the reviewed-v2 policy path, so `LegacyOnly` remains activation-safe while
  tier-less owners exist.
- Good: STOP source guards now fail if runtime code wires strong-owner minting,
  App Attest / DeviceCheck, or explicit approved/online signal tokens before
  the reviewed proof/signal design lands.
- Gap: no runtime path currently mints a strong tier for a real owner. The
  existing first-owner pair-device ceremony still signs a tier-less `PersonCert`
  for a key that proves the pairing nonce; it does not prove iOS/iPadOS
  provenance to the backend.
- Gap: device-pairing approve, mesh/relay/VPN membership, and remote attach
  still need their own default-safe gates after the strong-tier minting design.
  Device-pairing approve and household attach-token / terminal PTY remote
  attach are source-guarded so they cannot be folded into the current
  `reviewed-core-v2` flip or `owner_can_fan_out()` path without a separate
  reviewed rollout.

Product copy that says "only iPhone is owner" is not enough for this transition.
The state and backend gates need to encode or verify the accepted owner tier.

There are two distinct Mac-founder paths:

- **Local Workspace founder:** `initialize(claimToken: nil)` creates the
  household shell without `owner_auth`. This is local-only and cannot fan out
  because pair-machine requires `current_owner_auth()`.
- **First-owner pairing:** a client consumes the first pair-device ceremony and
  creates `owner_auth`. Product UX intends this to be the iPhone owner path, but
  the current ceremony does not supply server-verifiable provenance. It remains
  tier-less/weak until the strong-tier minting STOP is resolved.

## STOP: Strong-Tier Minting

The first-owner `pair-device/confirm` ceremony must remain tierless/weak unless
it is extended with a server-verifiable proof of strong owner provenance. The
current ceremony proves only possession of the submitted owner key and pairing
nonce; client-side Secure Enclave key creation and platform strings are not
backend-verifiable provenance.

Before any runtime path may mint `owner_auth_tier="strong"`:

- the Secure/Upgrade with iPhone ceremony must define the proof object the
  backend verifies;
- the proof must be challenge-bound and replay-safe, not a UI claim or request
  string;
- the strong tier must be minted only through a typed, reviewed backend path;
- existing pair-device confirmation remains tierless/weak until that proof
  exists;
- future fan-out gates, including device-pairing approve, mesh/relay/VPN
  membership, and remote attach, must be policy-gated/default-safe until strong
  minting is available for real owners.

This STOP blocks the enforcement flip, not Local Workspace. Local-only use stays
allowed; multi-device promotion waits for the strong-owner proof design.
The backend decision brief is tracked in theyos
`docs/followup-owner-auth-strong-tier-minting.md`. Its initial decision for the
transcript-vector slice is App Attest-backed Secure/Upgrade with iPhone using
App-Attest-specific provenance names. The verifier, exact runtime minting
ceremony, and fan-out enforcement remain unresolved until the post-decision
slices land in order.

## US-13: Upgrade Before Fan-Out

Before Local Workspace can promote to multi-device, the explicit upgrade rule is:

- keep `owner_auth_tier` / `owner_provenance` signed/verifiable as part of
  owner-auth certificate semantics, and preserve them through replay, restart,
  migration, and rollback paths. A loose config flag or UI-only marker is not
  sufficient;
- keep the strong tier as proof-derived owner-auth state, not as a writable side
  projection. A strong marker must be non-forgeable and minted only by the
  reviewed strong-owner ceremony; any state without that proof is weak by
  construction;
- mint that tier only through the reviewed iPhone owner path, not through the
  ambiguous first-owner key ceremony;
- keep the old `pair-device/confirm` nonce-prover path tier-less/weak unless it
  is extended with the required iOS/iPadOS provenance proof;
- make `pair-machine`, mesh enrollment, relay/VPN membership, and remote attach
  require that accepted tier. The pair-machine reviewed-v2 gate is staged; the
  remaining fan-out gates are still future work;
- preserve Local Workspace as local-only when the accepted tier is absent;
- define migration behavior for existing households and legacy or weak
  `PersonCert` values. They must be local-only or upgrade-required, never
  silently treated as strong;
- treat missing/tier-less provenance as non-strong by default. Fan-out is allowed
  only when an explicit strong marker is present and verifies;
- keep cross-language golden-vector coverage for any `PersonCert`/owner-auth
  schema change. The current owner-tier vectors pin Rust canonical emission and
  Swift decode parity before the gate can become flip-critical;
- keep the UI honest: "Secure with iPhone" is the transition, not a cosmetic
  warning.

This is a trust-model/schema decision, not a UI-only guard.

## Non-Goals

- Do not use native macOS platform passkey attestation as the root for this
  path. Apple synced passkeys do not provide the Apple Anonymous/device-bound
  proof required by the previous A-now design.
- Do not replace iPhone owner approval with `attestation=none` plus UV.
- Do not let Product A / nvpn / mesh assumptions become authority for this
  flow. Any mesh or relay integration is post-trust connectivity. The theyos
  source guard `product_a_transport_source_guard_does_not_become_owner_tier_authority`
  keeps Product A / relay-stream runtime out of the strong-tier classifier,
  strong-tier minter, and current `reviewed-core-v2` rollout.
- Do not touch the installed shipping `/Applications/Soyeht.app` while testing
  this path.
