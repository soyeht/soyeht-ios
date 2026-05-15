# Research: Phase 3 - Machine Join (Soyeht iPhone)

This document closes the local iPhone-side decisions that were left open in
`plan.md`. Cross-repo protocol shapes are sourced from:

- `/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/`
- `/Users/macstudio/Documents/theyos/specs/003-machine-join/data-model.md`
- `/Users/macstudio/Documents/theyos/docs/household-protocol.md`

Apple API behavior is constrained by the official UserNotifications,
Foundation, and LocalAuthentication documentation.

## R1 - BIP-39 wordlist pinning and locale policy

**Decision**: The iPhone bundles the standard BIP-0039 English wordlist only,
byte-identical to the theyos reference. The pinned bytes are already vendored
under `Packages/SoyehtCore/Sources/SoyehtCore/Resources/Wordlists/bip39-en.txt`
with SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
The Swift test target consumes the theyos golden-vector fixture byte-for-byte
from `HouseholdFixtures/MachineJoin/fingerprint_vectors.json`.

The earlier 10-locale idea is rejected for Phase 3. These six words are a
cryptographic checksum, not localized prose. The candidate console, theyos
owner-events payload, and Soyeht iPhone confirmation UI must render identical
ASCII words. A single English wordlist removes the most likely operator-visible
drift class: one side using localized words while the other side prints the
canonical installer output.

**Rationale**: The theyos contract `fingerprint-derivation.md` defines the
output as six lower-case BIP-39 English words joined by a single ASCII space.
The iPhone must match that exact display form. Cross-repo byte-equivalence is
more important than linguistic localization for this security primitive.

**Alternatives considered**:

- Ship 10 localized BIP-39 lists and choose by device locale. Rejected because
  it makes cross-device human comparison ambiguous and conflicts with theyos
  English-only vectors.
- Generate words from a project-owned dictionary. Rejected because BIP-39 is a
  stable, reviewed 2048-entry list and already has theyos test coverage.
- Store only the 16-vector fixture and derive words from it. Rejected because
  production must derive fingerprints for arbitrary machine keys.

## R2 - Fingerprint bit extraction and endianness lock

**Decision**: `OperatorFingerprint` derives:

```text
digest = BLAKE3-256(m_pub_sec1)
bits   = first 66 bits of digest, MSB-first
groups = six 11-bit indices, MSB-first
words  = BIP-39 English words at those indices
```

The implementation must use the explicit theyos bit extraction formulas from
`contracts/fingerprint-derivation.md`; the last six bits of `digest[8]` are
ignored. There is no nonce in the fingerprint input.

**Rationale**: The fingerprint is intended for side-by-side comparison between
the candidate console and the iPhone. Including `nonce` would make the words
change across regenerated windows for the same machine key and would diverge
from the theyos fixture. MSB-first extraction is locked by the cross-repo
fixture and by Swift tests that assert both per-word and joined-string forms.

**Alternatives considered**:

- `BLAKE3-256(m_pub || nonce)`. Rejected because the theyos contract hashes
  only the 33-byte SEC1 public key and because the fingerprint should identify
  the machine key, not the window.
- Little-endian 11-bit groups. Rejected because it produces different indices
  and the fixture would catch the drift.
- First 64 bits. Rejected because 64 does not split evenly into 11-bit BIP-39
  indices; 66 bits gives exactly six words.

## R3 - APNS background wakeup behavior on iOS 16/17/18

**Decision**: Treat APNS as a best-effort wakeup signal only. The authoritative
data path remains Tailscale long-poll over `GET /api/v1/household/owner-events`.
No correctness path may depend on an APNS delivery deadline.

The theyos Phase 3 contract supersedes the earlier local `{"v":1}` placeholder:
the canonical APNS body is exactly:

```json
{"aps":{"content-available":1}}
```

The server sends it with `apns-push-type: background`, `apns-priority: 5`, and
the app bundle topic. The iPhone handler must reject any user-info keys beyond
the APNS-required `aps.content-available` shape and must always fetch actual
owner-event content over Tailscale after wake.

**Rationale**: Apple's background-update notification model requires
`aps.content-available = 1`, treats background pushes as low priority, may
throttle excessive sends, and gives the app a bounded background execution
window to fetch data. Apple does not provide a latency SLA across iOS 16/17/18,
so Phase 3 uses APNS only to restart the long-poll path when the app is
backgrounded. The hard 5-minute join TTL is enforced by owner-events and queue
state, not by push timing.

**Alternatives considered**:

- Literal `{"v":1}` payload. Rejected because it is opaque but not a valid
  silent-push wakeup body.
- Put `hh_id`, candidate id, event cursor, or fingerprint in APNS. Rejected by
  Constitution III and the theyos opacity contract.
- Rely on APNS instead of foreground long-poll. Rejected because APNS delivery
  is opportunistic and throttled.

**Follow-up**: T005g/T044a must use the `{"aps":{"content-available":1}}`
canonical body. Any existing local task text or spec text that still mentions
`{"v":1}` is stale relative to theyos `contracts/owner-events.md`.

## R4 - `URLSessionWebSocketTask` resilience pattern

**Decision**: The gossip socket uses `URLSessionWebSocketTask` as a framed TLS
WebSocket transport and wraps it in a small state machine:

- one receive loop per connected task;
- periodic ping while connected;
- exponential reconnect with jitter after abnormal close or transport failure;
- explicit cancellation on session clear;
- cursor resume from durable local state before processing deltas;
- malformed frames fail the current connection and surface a typed diagnostic
  rather than being ignored.

**Rationale**: `URLSessionWebSocketTask` is the platform-native WebSocket API
available on iOS 16+. The app has low event volume, so correctness depends more
on clean reconnect/cursor handling than on throughput. A single receive loop
also makes cancellation and duplicate suppression testable.

**Alternatives considered**:

- Third-party WebSocket client. Rejected because Foundation already provides
  the needed API and adding a dependency would not improve the protocol model.
- Polling for membership changes. Rejected by FR-016 and SC-009; gossip is the
  sole reactive membership source.
- Treat disconnect as fatal until next app launch. Rejected because SC-007b
  requires reconnect-to-cursor behavior within the healthy-network budget.

## R5 - Owner-events long-poll cursor semantics

**Decision**: Owner-events cursor values are opaque client-side. The request
uses `since=<base64url-no-pad of deterministic CBOR uint>`, with zero for the
first poll. A `200 application/cbor` response returns
`OwnerEventsResponse = {v=1, events=[OwnerEvent...], next_cursor=uint}`. A
`204 No Content` means timeout with no cursor change.

The iPhone advances its stored owner-events cursor only after every returned
event that it chooses to accept has passed local verification and any resulting
side effect has committed. For `join-request`, that means:

1. verify the outer `OwnerEvent.signature` through the issuer MachineCert;
2. decode `payload.join_request_cbor`;
3. verify `JoinRequest.challenge_sig` under `m_pub`;
4. re-derive the fingerprint and compare it with `payload.fingerprint`;
5. enqueue into `JoinRequestQueue`.

If any step fails, the cursor stays at the last applied value and the failure
is surfaced as a typed `MachineJoinError`.

**Rationale**: Cursor advance is an acknowledgement. Advancing before enqueue
would allow a crash or validation failure to drop the owner-visible request
forever. Keeping the cursor opaque also gives theyos room to evolve from a
plain monotonic integer to an encoded vector-clock token without changing the
iPhone API surface.

**Alternatives considered**:

- Store `next_cursor` as soon as the HTTP response arrives. Rejected because it
  can skip unprocessed events.
- Use wall-clock timestamps for resume. Rejected because they do not provide a
  strict no-duplicate/no-gap contract under clock skew.
- Long-poll with JSON responses. Rejected by FR-030/FR-031; Phase 3 wire is
  deterministic CBOR only.

## R6 - LocalAuthentication taxonomy and biometric-only policy

**Decision**: The machine-join approval path uses
`LAPolicy.deviceOwnerAuthenticationWithBiometrics` through the existing
Secure-Enclave-backed `OwnerIdentityKey` access control. Only biometric
success may produce an owner-approval signature.

Typed mapping:

| LocalAuthentication outcome | Machine-join handling |
|---|---|
| success | produce `approval_sig` |
| `LAError.userCancel` | `MachineJoinError.biometricCancel`; revert queue entry to pending |
| `LAError.biometryLockout` | `MachineJoinError.biometricLockout`; revert queue entry to pending |
| `LAError.userFallback` | no passcode fallback; surface as non-success and do not sign |
| any signing/keychain failure after auth | `MachineJoinError.signingFailed`; clear the request |

**Rationale**: The feature's authorization moment is the owner's biometric
confirmation. Using the broader device-owner policy would allow passcode
fallback as a first-class path, which is not the contract here. Cancel and
lockout are non-terminal from the queue's perspective because no signature has
been produced and the request can remain visible until TTL.

**Alternatives considered**:

- Allow passcode fallback. Rejected because the feature explicitly gates
  approval on biometry and the Secure Enclave key is already configured for
  biometric use.
- Clear the queue on biometric cancel. Rejected because spec US3 says the card
  returns to pre-confirm state and remains pending until TTL.
- Retry biometry automatically. Rejected because silent retry would obscure
  the owner's explicit cancel.

## R7 - Household snapshot signature scheme

**Decision**: The iPhone-side snapshot bootstrapper expects a root-signed CBOR
envelope:

```cbor
HouseholdSnapshotEnvelope = {
  "v": 1,
  "snapshot": HouseholdSnapshotBody,
  "signature": bytes(64)
}
```

`signature` is P-256 ECDSA raw `r || s` over canonical
CBOR(`HouseholdSnapshotBody`) and verifies directly against the stored
`hh_pub`. The body carries `hh_id`, membership MachineCerts, CRL entries, an
`as_of` cursor/vector-clock token, and `head_event_hash`. The bootstrapper
applies members and CRL entries atomically before starting the gossip consumer.

**Rationale**: The iPhone already trusts `hh_pub` from Phase 2. Root-signing
the snapshot avoids a bootstrap dependency on a particular machine issuer
before the membership set has been validated, and it cleanly seeds CRL state
for SC-011 before any streamed `machine_added` event is accepted.

**Alternatives considered**:

- Machine-signed snapshot only. Rejected for first-connection bootstrapping:
  the client would need to trust a member cert before the snapshot has seeded
  the member set and CRL.
- Trust TLS/Tailscale transport without snapshot signature. Rejected because
  Phase 3 membership state is a signed-cert protocol; transport is not the
  state integrity boundary.
- Verify only `head_event_hash`. Rejected because it proves log linkage only
  after the client has a trusted log base; fresh installs need a directly
  verifiable root.

**Follow-up**: `contracts/household-snapshot.md` (T005h) must co-version this
envelope with theyos. Current theyos protocol documentation defines a snapshot
body but does not yet pin the iPhone-required signature envelope in a Phase 3
contract file.

## References

- Apple Developer Documentation: `Pushing background updates to your App`.
- Apple Developer Documentation Archive: `Creating the Remote Notification Payload`.
- Apple Developer Documentation: `URLSessionWebSocketTask`.
- Apple Developer Documentation: `LAError` and `LAPolicy.deviceOwnerAuthenticationWithBiometrics`.
- theyos `specs/003-machine-join/contracts/fingerprint-derivation.md`.
- theyos `specs/003-machine-join/contracts/pair-machine-url.md`.
- theyos `specs/003-machine-join/contracts/owner-events.md`.
- theyos `docs/household-protocol.md` sections 10-13.
