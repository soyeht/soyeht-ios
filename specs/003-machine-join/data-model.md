# Data Model: Phase 3 - Machine Join (Soyeht iPhone)

This document defines the iPhone-side model surface for machine join. Wire
contracts are deterministic CBOR per RFC 8949 section 4.2.1 unless explicitly
called out as local persistence. Public keys are 33-byte SEC1 compressed P-256.
Signatures are 64-byte raw P-256 ECDSA `r || s`. Hashes are BLAKE3-256.

The iPhone never creates or signs a `MachineCert`. It verifies join requests,
collects biometric owner approval, submits `OwnerApproval`, and mutates local
membership only after validated snapshot/gossip state.

## Encoding and Identity Conventions

| Name | Shape | Notes |
|---|---|---|
| `hh_id` | text | Household id from Phase 2, derived from `hh_pub` by theyos |
| `p_id` | text | Owner PersonCert subject id |
| `m_id` | text | `m_` + base32-lower-no-pad BLAKE3-256 of `m_pub` |
| `m_pub` | bytes(33) | SEC1 compressed P-256 point, prefix `0x02` or `0x03` |
| `nonce` | bytes(32) | Join-window nonce, single-use server-side |
| `signature` | bytes(64) | Raw P-256 ECDSA `r || s` |
| `cursor` | uint or opaque token | Owner-events/gossip resume position; callers treat it opaquely when encoded into URLs |

## PairMachineQR

Scanned URI:

```text
soyeht://household/pair-machine?
  v=1
  &m_pub=<base64url-no-pad bytes(33)>
  &nonce=<base64url-no-pad bytes(32)>
  &hostname=<percent-encoded UTF-8, 1..64 bytes>
  &platform=macos|linux-nix|linux-other
  &transport=lan|tailscale
  &addr=<host:port>
  &challenge_sig=<base64url-no-pad bytes(64)>
  &ttl=<unix seconds>
```

Validation:

- `ttl` must be in the future and no more than 300 seconds from issuance.
- `m_pub`, `nonce`, `hostname`, `platform`, and `challenge_sig` are bound by
  `JoinChallenge`.
- `transport` and `addr` are reachability hints; tampering can cause denial of
  service but cannot cause a different candidate to be authorized.

## JoinChallenge

Signed by the candidate at install time and reconstructed by the iPhone before
presenting a confirmation card.

```cbor
JoinChallenge = {
  "v": 1,
  "purpose": "machine-join-request",
  "m_pub": bytes(33),
  "nonce": bytes(32),
  "hostname": text,
  "platform": "macos" | "linux-nix" | "linux-other"
}
```

Signature verification:

- signature input is canonical CBOR of the map above;
- verifier key is `m_pub`;
- signature bytes are `challenge_sig`;
- any failure maps to `MachineJoinError.qrInvalid(.challengeSigInvalid)` or
  the equivalent owner-event rejection.

## JoinRequest

Wire CBOR sent to the founding machine by the iPhone after QR scan, or fetched
by theyos M1 from M2's local seed listener in the Bonjour path.

```cbor
JoinRequest = {
  "v": 1,
  "m_pub": bytes(33),
  "hostname": text,
  "platform": "macos" | "linux-nix" | "linux-other",
  "nonce": bytes(32),
  "addr": text,
  "transport": "lan" | "tailscale",
  "challenge_sig": bytes(64)
}
```

The iPhone builds these bytes from `PairMachineQR` for the QR path. For the
owner-events path, the iPhone receives these exact bytes inside
`OwnerEvent.payload.join_request_cbor`.

## JoinRequestEnvelope

iPhone in-memory unification layer for both transports.

| Field | Type | Source | Rules |
|---|---|---|---|
| `householdId` | text | Local Phase 2 session | Must equal active household before signing |
| `machinePublicKey` | Data | QR or `join_request_cbor` | 33-byte SEC1 P-256 |
| `nonce` | Data | QR or `join_request_cbor` | 32 bytes |
| `rawHostname` | String | QR or `join_request_cbor` | Stored raw; UI must use `JoinRequestSafeRenderer` |
| `rawPlatform` | String | QR or `join_request_cbor` | Stored raw; UI must use `JoinRequestSafeRenderer` |
| `candidateAddress` | String | `addr` | Reachability hint, never a trust input |
| `ttlUnix` | UInt64 | QR `ttl` or owner-event `expiry` | Hard 5-minute pending window |
| `challengeSignature` | Data | `challenge_sig` | Always present, 64 bytes |
| `transportOrigin` | enum | Local classification | `bonjour-shortcut`, `qr-lan`, or `qr-tailscale` |
| `receivedAt` | Date | Local clock | Sort and TTL display only |

Derived values:

- `idempotencyKey = householdId | base64url(m_pub) | base64url(nonce)`
- `displayHostname = JoinRequestSafeRenderer.render(rawHostname)`
- `displayPlatform = JoinRequestSafeRenderer.render(rawPlatform)`
- `isExpired(now) = ttlUnix <= now`

The envelope does not prove validity by construction; callers must only create
it after FR-029 challenge verification has passed.

## OperatorFingerprint

Human-comparable anti-phishing checksum over the candidate machine key.

| Field | Type | Rules |
|---|---|---|
| `machinePublicKey` | bytes(33) | SEC1 compressed P-256 |
| `digestFull` | bytes(32) | `BLAKE3-256(machinePublicKey)`; diagnostics only |
| `indices` | `[UInt16 x 6]` | first 66 digest bits, six MSB-first 11-bit indices |
| `words` | `[String x 6]` | BIP-39 English words at `indices` |
| `display` | text | `words.joined(separator: " ")`, lower-case ASCII |

There is no nonce, household id, hostname, or platform in this derivation.
Those fields are bound separately by `challenge_sig`.

## OperatorAuthorization

The owner approval has an inner signed context and an outer wire body. The
decision is path-conditional (`approve` or `decline`), not a CBOR field.

```cbor
OwnerApprovalContext = {
  "v": 1,
  "purpose": "owner-approve-join",
  "hh_id": text,
  "p_id": text,
  "cursor": uint,
  "challenge_sig": bytes(64),
  "timestamp": uint
}
```

```cbor
OwnerApproval = {
  "v": 1,
  "cursor": uint,
  "approval_sig": bytes(64)
}
```

Local result type:

| Field | Type | Rules |
|---|---|---|
| `approvalSignature` | Data | Raw P-256 `r || s` over canonical `OwnerApprovalContext` |
| `outerBody` | Data | Canonical CBOR `OwnerApproval` |
| `signedContext` | Data | Exact bytes signed by the owner key |
| `cursor` | UInt64 | Must match path cursor and owner-event cursor |
| `timestamp` | UInt64 | Unix seconds; server replay tolerance +/-60 seconds |

Preconditions:

- `JoinRequestEnvelope.householdId == localHouseholdId`;
- owner PersonCert is valid for `p_id`;
- biometric-only Secure Enclave signing succeeds.

Errors map through `MachineJoinError`:

- household mismatch -> `hhMismatch`;
- user cancel -> `biometricCancel`;
- biometry lockout -> `biometricLockout`;
- signing failure -> `signingFailed`.

## JoinRequestQueue

Actor-owned local pending store. This is not durable across app reinstall.

| Field | Type | Rules |
|---|---|---|
| `entries` | map idempotencyKey -> entry | At most one entry per `(hh_id, m_pub, nonce)` |
| `Entry.envelope` | `JoinRequestEnvelope` | Verified request being presented |
| `Entry.state` | `pending` or `inFlight` | `inFlight` begins after Confirm tap |
| `events` | `AsyncStream<Event>` | Fan-out to card stack / diagnostics |

Lifecycle:

1. `enqueue` inserts a new `pending` entry and publishes `added`.
2. `claim` transitions `pending -> inFlight`; a second claim returns nil.
3. `confirmClaim` removes `inFlight` on local success, unless TTL elapsed.
4. `revertClaim` transitions `inFlight -> pending` for biometric cancel/lockout
   only, unless TTL elapsed.
5. `failClaim` removes pending or in-flight entries for terminal failures.
6. `acknowledgeByMachine(publicKey:)` removes any matching entry after gossip
   proves the machine joined.
7. `pendingEntries(now:)` eagerly expires all TTL-elapsed entries.

Removal reasons:

- `confirmed`
- `expired`
- `acknowledgedByGossip`
- `dismissed`
- `failed(MachineJoinError)`

## OwnerEventsLongPoll Models

Request:

```http
GET /api/v1/household/owner-events?since=<base64url-no-pad-cbor-uint>
Authorization: Soyeht-PoP ...
```

Response:

```cbor
OwnerEventsResponse = {
  "v": 1,
  "events": [OwnerEvent],
  "next_cursor": uint
}
```

`204 No Content` has no body and no cursor change.

`OwnerEvent`:

```cbor
OwnerEvent = {
  "v": 1,
  "cursor": uint,
  "ts": uint,
  "type": text,
  "payload": map,
  "issuer_m_id": text,
  "signature": bytes(64)
}
```

Accepted owner-event types in this feature:

| Type | Payload | iPhone action |
|---|---|---|
| `join-request` | `{join_request_cbor: bytes, fingerprint: text, expiry: uint}` | Verify event signature, decode JoinRequest, verify challenge, compare fingerprint, enqueue |
| `machine-joined` | `{m_pub: bytes, m_id: text, hostname: text, joined_at: uint}` | Optional queue cleanup; authoritative membership update still comes from snapshot/gossip |
| `join-cancelled` | `{m_pub: bytes, reason: text}` | Clear matching pending card when present |

Cursor advance occurs only after accepted events have committed local side
effects.

## HouseholdGossipConsumer Models

The exact WebSocket envelope is pinned by T005f. The iPhone-side consumer uses
these normalized fields regardless of whether the wire cursor is a monotonic
integer or an encoded vector-clock token.

```cbor
GossipEvent = {
  "v": 1,
  "event_id": bytes(32),       // BLAKE3-256 of canonical signed event, or server-provided equivalent
  "cursor": bytes | uint,      // opaque resume token
  "type": text,
  "ts": uint,
  "issuer_m_id": text,
  "payload": map,
  "signature": bytes(64)
}
```

Accepted gossip variants:

### `machine_added`

```cbor
payload = {
  "machine_cert": bytes        // canonical CBOR MachineCert
}
```

Pipeline:

1. dedupe by `event_id`;
2. verify event signature through issuer MachineCert;
3. decode `machine_cert`;
4. validate `MachineCert` against local `hh_pub`, `hh_id`, and `CRLStore`;
5. add/replace `HouseholdMembershipStore` member from cert;
6. persist cursor after mutation.

### `machine_revoked`

```cbor
payload = {
  "revocation": RevocationEntry
}
```

Pipeline:

1. dedupe by `event_id`;
2. verify event signature;
3. validate the revocation entry signature according to the household
   revocation contract;
4. append to `CRLStore`;
5. remove matching machine from `HouseholdMembershipStore`;
6. persist cursor after mutation.

Rejected gossip events do not mutate membership. They produce a diagnostic
entry with event id, type, and sanitized reason only.

## MachineCert

Canonical CBOR cert issued by the household root. The iPhone validates these
certs but never signs them.

```cbor
MachineCert = {
  "v": 1,
  "type": "machine",
  "hh_id": text,
  "m_id": text,
  "m_pub": bytes(33),
  "hostname": text,
  "platform": "macos" | "linux-nix" | "linux-other",
  "joined_at": uint,
  "issued_by": text,
  "signature": bytes(64)
}
```

Validation:

- canonical CBOR byte-for-byte re-encoding matches the received bytes;
- no unknown fields;
- `v == 1`;
- `type == "machine"`;
- `m_pub` is a compressed P-256 point;
- `m_id == identifier(m_pub, kind: machine)`;
- `hh_id == local household id`;
- `issued_by == hh_id`;
- `joined_at` is not future-dated beyond clock skew tolerance;
- signature verifies against stored `hh_pub` over canonical map excluding
  `signature`;
- `CRLStore` does not contain `m_id`.

Local projection:

| Field | Type |
|---|---|
| `machineId` | String |
| `machinePublicKey` | Data |
| `hostname` | String |
| `platform` | `MachineCert.Platform` |
| `joinedAt` | Date |

## HouseholdMembershipStore

In-memory, observable membership projection driven by snapshot and gossip.

| Field | Type | Rules |
|---|---|---|
| `membersById` | map `m_id -> HouseholdMember` | Idempotent add/replace |
| `events` | `AsyncStream<Event>` | Every committed mutation fans out once |

Events:

- `added(HouseholdMember)`
- `replaced(HouseholdMember)`
- `removed(machineId: String)`

Snapshot bootstrap seeds this store before gossip deltas start. Gossip deltas
then keep it reactive without polling.

## RevocationEntry

Local CRL entry. Wire signature validation is pinned by the snapshot/gossip
contracts; local storage keeps the fields needed to reject future certs.

| Field | Type | Rules |
|---|---|---|
| `subject_id` / `subjectId` | text | `m_id`, `p_id`, or `d_id` |
| `revoked_at` / `revokedAt` | uint / Date | Time revocation was issued |
| `reason` | text | Sanitized diagnostic/display category |
| `cascade` | text enum | `self_only` or `machine_and_dependents` |
| `signature` | bytes(64) | Household-authorized revocation proof |

Local Swift type uses Codable field names. Wire contracts should encode snake
case CBOR keys.

## CRLStore

Keychain-backed actor for revocation state.

| Field | Type | Rules |
|---|---|---|
| `entriesById` | map subject id -> `RevocationEntry` | Dedupe on subject id |
| `snapshotCursor` | UInt64? | Cursor of boot snapshot, when supplied |
| `lastUpdatedAt` | Date? | Local persistence timestamp |
| `additions` | `AsyncStream<RevocationEntry>` | Emits each newly inserted entry once |

Operations:

- `contains(subjectId)` gates MachineCert validation.
- `append(entry)` inserts one validated delta and persists.
- `seedFromSnapshot(entries, snapshotCursor)` inserts snapshot entries,
  persists once, and emits only newly inserted entries.
- `clear()` deletes Keychain state on session clear.

Persistence is JSON-encoded local state stored through `HouseholdSecureStoring`;
this is deliberately separate from deterministic-CBOR wire contracts.

## HouseholdSnapshot

Boot-time signed bundle fetched before gossip starts.

```cbor
HouseholdSnapshotEnvelope = {
  "v": 1,
  "snapshot": HouseholdSnapshotBody,
  "signature": bytes(64)
}
```

```cbor
HouseholdSnapshotBody = {
  "v": 1,
  "hh_id": text,
  "as_of_cursor": uint / bytes,
  "as_of_vc": map,             // optional when theyos exposes vector-clock resume
  "members": [MachineCert],
  "crl": [RevocationEntry],
  "head_event_hash": bytes(32),
  "issued_at": uint
}
```

Verification:

- decode envelope and body as deterministic CBOR;
- `hh_id` equals local active household id;
- verify `signature` against stored `hh_pub` over canonical CBOR body;
- validate each `MachineCert` with the snapshot CRL included in the same body;
- validate each revocation entry according to the revocation contract;
- apply CRL and members atomically before gossip deltas are processed.

Application order:

1. fetch `GET /api/v1/household/snapshot` with Phase 2 household PoP;
2. verify envelope signature;
3. seed `CRLStore`;
4. build validated `HouseholdMember` values from certs not in CRL;
5. replace `HouseholdMembershipStore` initial state;
6. persist snapshot cursor/resume token;
7. start `HouseholdGossipConsumer` from the snapshot cursor.

If any validation fails, no partial CRL or membership mutation is committed.

## Phase 3 Error Surface

All boundary errors map to `MachineJoinError` before reaching UI:

| Source | Local mapping |
|---|---|
| Pair-machine QR parse/verify | `qrInvalid` or `qrExpired` |
| Household mismatch | `hhMismatch` |
| Biometric cancel/lockout | `biometricCancel` / `biometricLockout` |
| Phase 3 HTTP content-type/CBOR errors | `protocolViolation` |
| Server CBOR error envelope | `serverError` or specific mapped case |
| Fingerprint cross-check mismatch | `derivationDrift` |
| MachineCert validation | `certValidationFailed` |
| Gossip reconnect exhaustion | `gossipDisconnect` |
| Secure Enclave signing failure | `signingFailed` |

User-facing text is localized in `Localizable.xcstrings`; diagnostics must not
log secrets, raw cert bodies, APNS tokens, or private routing material.
