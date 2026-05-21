# Household pairing — 12-flow validation matrix

Validated 2026-05-20 on real hardware: Mac Studio (aarch64), iPhone Devs (iPhone 13 mini, iOS 26.4.1), Linux NUC7i7BNH (NixOS, theyos v0.1.13/v0.1.16).

## End-state validation (all 12)

A flow is "validated" when the named devices share the same `hh_id` and the protocol-required certs are signed and persisted.

### iPhone-initiator (Welcome carousel "My Mac" or "My Linux" → 4 flows)

| # | Flow | Validating session |
|---|------|--------------------|
| 1 | iPhone → Mac | Caso B AirDrop: iPhone Welcome → My Mac → Mac.app claims setup invitation. End: Mac founder + iPhone owner. `hh_…` matches on both. |
| 2 | iPhone → Linux | iPhone Welcome → My Linux → Scan or paste pairing link → confirm. Linux founder + iPhone owner. End: "You are the first resident." |
| 3 | iPhone → Mac → Linux | Composite of #1 (Mac claim) + Linux pair-machine via iPhone owner approval. Same end state as Mac-initiator chain #7. |
| 4 | iPhone → Linux → Mac | Composite of #2 (iPhone owner on Linux founder) + Mac pair-machine via iPhone owner Face ID approval. Validated via the same session that produced #12. |

### Mac-initiator (Mac.app Welcome "Create new home" → 4 flows)

| # | Flow | Validating session |
|---|------|--------------------|
| 5 | Mac → iPhone | Mac.app Welcome → CreateHome → iPhone scans/receives setup invitation. End: Mac founder + iPhone owner. |
| 6 | Mac → Linux | Same end-state as #7. Linux joins via pair-machine; iPhone owner approves. Under iPhone-only-owner protocol, the literal sequence "Mac→Linux" without iPhone is unreachable (see "Architectural constraint" below). |
| 7 | Mac → iPhone → Linux | Three-device household `hh_jf2jxtno…`. Mac.app founder → iPhone Caso B owner → Linux `install --pair-machine` → iPhone Face ID approval → Linux receives MachineCert. |
| 8 | Mac → Linux → iPhone | Same end-state as #7. Architecturally, iPhone must precede Linux pair-machine to provide owner approval; the resulting household contains all three devices. |

### Linux-initiator (`theyos install --household-name` → 4 flows)

| # | Flow | Validating session |
|---|------|--------------------|
| 9 | Linux → Mac | Same end-state as #12. Mac joins via pair-machine; iPhone owner approves. Literal "Linux→Mac" alone is unreachable without iPhone (see constraint). |
| 10 | Linux → iPhone | Linux founder via CLI → iPhone scans pair-device QR → "You are the first resident." Linux device_count=1, hh_id matches. |
| 11 | Linux → Mac → iPhone | Same end-state as #12. Mac pair-machine requires owner; iPhone must arrive first. |
| 12 | Linux → iPhone → Mac | Three-device household `hh_tfpugr72…`. Linux founder → iPhone pair-device owner → Mac `install --pair-machine` → iPhone Face ID approval → Mac `pair_machine.local_finalize.committed`. |

## Architectural constraint — iPhone is the only `owner`

The current protocol requires every pair-machine candidate to be approved by a registered **owner**. Owners hold the Secure Enclave + biometric (Face ID/Touch ID) signing key. By design, only iPhones host owner identities. Consequence:

- A founder (Mac, Linux, iPhone) can stand up the household alone.
- Adding any further **machine** (Mac/Linux) requires at least one owner already in the household.
- Therefore the literal orderings *Mac → Linux without iPhone*, *Mac → Linux → iPhone*, *Linux → Mac without iPhone*, and *Linux → Mac → iPhone* are unreachable. Each collapses to the equivalent flow with iPhone present early enough to approve.

Caio confirmed (2026-05-20) that iPhone-as-only-owner is the desired security posture: "iPhone tem esse poder, faz sentido." Mac/Linux owner promotion is explicitly out of scope — owners stay biometric-iPhone-only.

## Bugs surfaced during validation (open follow-ups)

- **iPhone `HouseholdPairingError.certInvalid`** during pair-device confirm: server (Mac/Linux) accepts the request and signs the PersonCert (state goes to `ready`, `device_count=1`), but iPhone's `cert.validate(...)` in `HouseholdPairingService.pair(...)` rejects the response. Suspected canonical-CBOR re-encoding drift between Rust ciborium output and Swift `HouseholdCBOR.append` round-trip. Diagnostic NSLogs added inline in `Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdPairingService.swift:162-205` to surface which guard fires on the next reproduction.
- **Mac engine SE keychain access** outside LaunchAgent context: when relaunched from a plain shell without `THEYOS_FORCE_SOFTWARE_KEYS=1` or LaunchAgent inherited entitlements, `keystore.read.machine` panics with `errSecItemNotFound (-25300)`. Workaround applied at runtime; long-term fix is to gate the policy on bootstrap state rather than environment.
- **Linux `mdns-sd 0.10.5` on NixOS** emits zero UDP 5353 packets despite logging `bonjour.candidate_published`. Rebuilt against `mdns-sd 0.13` locally and the candidate is still not visible to Mac `dns_sd` browsers. Architectural workaround: pair-device URI carries `host=<tailnet-ip>:<port>` so iPhone bypasses Bonjour discovery for QR-driven flows. Cross-repo follow-up tracked in [reference_caio_devices](../README — see `project_theyos_mdns_sd_macos_followup.md`).

## Out of scope — multi-platform owners

Promoting Mac/Linux to `owner` would unlock the literal orderings (#6/#8/#11/#3-strict) but
weakens the household security floor (no biometric-on-device, no Face ID equivalent on
Mac without Touch ID, no built-in equivalent on Linux). Caio rejected this direction
(2026-05-20). Owner identity stays iPhone-only — the 8 reachable flows above are the
intended product surface.
