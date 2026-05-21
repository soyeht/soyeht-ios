# iPhone-loss recovery — implementation plan

Goal: close the recovery promise surfaced in `HowToRecoverView` and
`RecoveryMessageView` (today purely decorative) with a real end-to-end
mechanism. Preserves the iPhone-only-owner protocol decision (Mac/Linux
do not become regular owners) by treating recovery as an exceptional ceremony.

Owner of this plan: next session + agent. This document is the brief.

## Product decision (already made)

- **Option #1 — Mac approves recovery via Touch ID** (default path)
- **Option #2 — BIP-39 6-word recovery code** (opt-in fallback)
- Option #3 (recovery contacts) deferred to v2.

Rationale: #1 covers the happy case (user has a Mac in the same home, lost
iPhone, gets a new iPhone). #2 covers the unhappy edge case (user has only
iPhones — first iPhone lost without backup). Both keep the "iPhone-only-owner
in steady state" invariant by treating Mac Touch ID as a one-shot recovery
authority that does **not** make Mac a regular owner.

## What exists today (do not duplicate)

- `household-rs/src/shamir.rs` — byte-wise GF(256) Shamir secret sharing,
  currently `k=2, n=2`. Two shards, two devices. Lose either device and
  `HH_priv` is permanently unrecoverable. **Must upgrade to `k=2, n=N`** (any
  2-of-N reconstruct) so recovery is mathematically possible.
- `household-rs/src/chain.rs:79-80` — sole-shard mode `shamir_n=1` initially,
  transitions to `shamir_n>1` on first machine join.
- `RecoveryMessageView.swift` + `KeyHandoffMetaphorView` — decorative
  animation post-pair. Reuse the metaphor + safety footer.
- `HowToRecoverView.swift` in Settings — explainer screen. Reuse.

## Implementation phases

### Phase R0 — Shamir n=N upgrade (one-time foundational change)

**Files (engine):**
- `theyos-engine-tailnet-url/admin/rust/household-rs/src/shamir.rs` — split/reconstruct
  must accept `k=2, n=N` (currently coded as 2-of-2 byte-wise).
- `household-rs/src/chain.rs` — on each new pair-device/pair-machine, re-split
  `HH_priv` into N shards (one per device) so the new device receives its shard
  during the join handshake.
- `server-rs/src/handlers_pair_device.rs` + `handlers_pair_machine.rs` — return
  a fresh shard alongside the cert response.

**Test (engine):** `shamir.rs` unit test for `(k=2, n=3)` round-trip on 1000
random secrets, plus rejection of duplicate share indices and quorum
shortfalls.

### Phase R1 — Mac-approves recovery path (#1)

**iPhone side (new iPhone, no household):**
- `TerminalApp/Soyeht/Onboarding/...` — add "Recover existing home" path in
  Welcome carousel beside "Create new home" / "Join existing".
- New view `RecoverFromBonjourView` browses `_soyeht-household._tcp` candidates
  on the LAN/Tailnet, lists matching households (or the single one Caio has).
- On select, iPhone POSTs `/household/recovery-request` to the chosen Mac,
  including a fresh iPhone public key (new SE-backed owner identity).
- Polls for `recovery.approved` → receives quorum-reconstructed `HH_priv`
  encrypted to the iPhone public key + a new PersonCert.
- Validates, saves session, lands in HouseholdHomeView.

**Mac.app side (owner-recovering Mac):**
- New file: `TerminalApp/SoyehtMac/Recovery/RecoveryApprovalView.swift`.
- `SetupInvitationListener`-style background listener for incoming recovery
  requests on the household-rs HTTP surface.
- On request: show notification + sheet "iPhone novo quer recuperar acesso à
  Home Caio. Aprovar?" with the new iPhone's BIP-39 6-word fingerprint for
  out-of-band verification.
- Touch ID gate via `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.
- On approve: Mac contributes its shard, broadcasts `recovery.approval`
  envelope to other machines (Linux contributes its shard too).
- Once `k=2` shards collected, reconstruct `HH_priv` server-side, sign new
  PersonCert for the iPhone, encrypt the shard for the new iPhone, deliver.

**Engine side (Rust):**
- `server-rs/src/handlers_recovery.rs` (new) — `POST /household/recovery-request`,
  `POST /household/recovery-approve`, `GET /household/recovery-status`.
- Quorum collection: similar to `JoinRequestQueue` but for recovery envelopes.
- Audit log: every recovery request + approval persisted (`recovery_audit.cbor`)
  so a stolen Mac can't silently recover an attacker's iPhone — Caio sees the
  audit trail next time he opens any device.

**UX safety net:**
- Recovery requests visible in iPhone Settings → About Home → "Recent activity"
  (so the legit Caio sees suspicious recoveries if a stolen Mac is used).
- Recovery requests on Linux (no UI) surface via local mDNS broadcast to all
  household devices so Caio's iPhone (if still owned) can deny remotely.

### Phase R2 — BIP-39 6-word recovery code (#2)

**During initial pair (iPhone first owner):**
- After `RecoveryMessageView` (post-pair animation), surface new view
  `RecoveryCodeView` with 6 BIP-39 words derived from a 16-byte seed.
- The seed is split into a fresh Shamir share that goes to a "virtual paper
  device" (`m_id = m_paper_<hash>`) registered in the household at `n+1`.
- `ShareLink` actions: Save to Apple Notes, Save to Passwords, Print, Copy.
- Settings → About Home → "View recovery words" re-shows on demand (re-derived
  from the stored shard, biometrically gated).

**Recovery using only the 6 words (no Mac present):**
- New iPhone Welcome → "I have a recovery code" → enter 6 words via
  `BIP39EntryView` (matches existing fingerprint word entry UX).
- Words reconstruct the paper shard locally on iPhone. iPhone broadcasts a
  recovery request with this shard (proof-of-possession via reconstructed scalar
  signing a challenge from any reachable household device).
- If at least one other device (Mac/Linux) is reachable, that device's shard
  + the paper shard reach quorum `k=2` → `HH_priv` reconstructed → new
  PersonCert minted for the iPhone.

**Engine side:**
- Treat paper shard as a special owner with capability `recovery_only`. Cannot
  approve pair-machine, cannot mint owner certs in normal flow — only signs
  recovery envelopes.

### Phase R3 — UX polish

- `HowToRecoverView` body rewrite to match the actual implemented mechanism
  (cite "Mac approves" + "6 words" instead of vague "another Mac recovers").
- `RecoveryMessageView` CTA: "Save recovery code" if user opted in, "Continue"
  otherwise.
- Recovery activity log visible in Settings on every device.

## Regression checklist — the 8 reachable flows MUST keep working

Every change in R0/R1/R2/R3 risks breaking the 8 validated flows (see
`docs/household-12-flow-matrix.md`). Before merging any phase, **re-run all 8
flows on real hardware** (Mac Studio + iPhone Devs + Linux NUC7i7BNH):

| # | Initiator | Devices in household | Validation criterion |
|---|-----------|---------------------|----------------------|
| 1 | iPhone Welcome → My Mac (Caso B AirDrop) | Mac founder + iPhone owner | both sides `hh_id` match, state=ready |
| 2 | iPhone Welcome → My Linux → Scan link | Linux founder + iPhone owner | iPhone "first resident" shown, Linux device_count=1 |
| 5 | Mac.app Welcome → CreateHome | Mac founder + iPhone owner | iPhone setup-invitation claimed |
| 7 | Mac founder → iPhone owner → Linux pair-machine | 3-device household | iPhone owner approves via Face ID, Linux `local_finalize.committed` |
| 9 | Linux install → Mac.app pair-device | Linux founder + Mac+iPhone owner chain | Mac engine joins household via iPhone approval |
| 10 | Linux install → iPhone scans QR | Linux founder + iPhone owner | iPhone first resident, hh_id matches |
| 12 | Linux founder → iPhone owner → Mac pair-machine | 3-device household | Mac `local_finalize.committed` |
| (Composite #3) | iPhone Welcome → My Mac → then Linux | 3-device household | same as #7, exercised from iPhone Welcome |

Treat any flow that regresses as a release-blocking bug — these are the
product surface area. Any PR touching `HouseholdPairingService`,
`SetupInvitationListener`, `handlers_pair_device`, `handlers_pair_machine`,
`handlers_owner_events`, `shamir`, `chain`, `keystore`, `OwnerIdentityKey`, or
`HouseholdSessionStore` should attach proof of the 8-flow run.

## Open questions for the implementing agent

1. **Audit trail visibility** — recovery approvals on Mac without iPhone
   present mean Caio's legit iPhone (if rediscovered) has no chance to
   reject. Acceptable, or require dual-approval (Mac + delayed reject window)?
2. **Paper shard storage location** — Apple Notes (iCloud) is convenient but
   syncs to all Apple ID devices. Passwords app (System Settings → Passwords)
   is more secure but lower discoverability. Default to Notes with copy-to-
   Passwords as opt-in?
3. **Linux's role in recovery without Mac** — if user only has iPhone+Linux
   (no Mac with Touch ID), how does recovery work? Probably: paper code path
   (#2) is mandatory in that topology, surface a setup-time warning.

## Suggested commit cadence

Each phase = one PR. Each PR includes the 8-flow regression evidence.

R0 (Shamir n=N) → R1 (Mac approves) → R2 (paper code) → R3 (polish).

Estimated effort: R0 ~3 days, R1 ~1 week, R2 ~1 week, R3 ~2 days.
