# Contract: Household Gossip Consumer

This is the iPhone-side Phase 3 consumption contract for membership deltas.
It is derived from protocol section 10 and must be co-versioned with the theyos
gossip contract when theyos publishes a dedicated Phase 3/4 document.

## WebSocket

```http
GET /api/v1/household/gossip
Upgrade: websocket
Authorization: Soyeht-PoP ...
```

The app connects to any reachable household member over Tailscale. The socket
is scoped to signed household events. It is not used for owner approval.

## Lifecycle

- Bootstrap first with `GET /api/v1/household/snapshot`.
- Start gossip only after snapshot CRL and membership are applied atomically.
- Keep one active receive loop.
- Send ping frames periodically while connected.
- On abnormal close, reconnect with exponential backoff and resume cursor.
- On session clear, cancel the socket and stop processing frames.

Malformed frames close the current connection and produce a sanitized
diagnostic. They do not mutate membership.

## Event Envelope

Normalized iPhone shape:

```cbor
GossipEvent = {
  "v": 1,
  "event_id": bytes(32),
  "cursor": uint / bytes,
  "type": text,
  "ts": uint,
  "issuer_m_id": text,
  "payload": map,
  "signature": bytes(64)
}
```

If the theyos wire event uses vector-clock fields from protocol section 10, the
consumer normalizes the event hash or vector-clock token into `event_id` and
`cursor` before applying local policy.

## Accepted Types

Phase 3 iPhone processes only:

- `machine_added`
- `machine_revoked`

All other event types are ignored after envelope validation and cursor handling
policy is applied by the concrete implementation. Ignored events must not
mutate `HouseholdMembershipStore`.

## `machine_added`

```cbor
payload = {
  "machine_cert": bytes
}
```

Pipeline:

1. Deduplicate by `event_id`.
2. Verify event signature under `issuer_m_id`'s MachineCert chained to `hh_pub`.
3. Decode `payload.machine_cert` as canonical `MachineCert`.
4. Validate the cert:
   - canonical CBOR re-encoding matches;
   - `v == 1`;
   - `type == "machine"`;
   - `hh_id == local hh_id`;
   - `issued_by == hh_id`;
   - `m_id == identifier(m_pub)`;
   - signature verifies under `hh_pub`;
   - `m_id` is not present in `CRLStore`.
5. Add or replace the member in `HouseholdMembershipStore`.
6. Clear matching pending queue entries by `m_pub`.
7. Persist cursor after mutation.

Any validation failure maps to
`MachineJoinError.certValidationFailed(reason: ...)` and does not mutate
membership.

## `machine_revoked`

```cbor
payload = {
  "revocation": RevocationEntry
}
```

`RevocationEntry` wire fields:

```cbor
RevocationEntry = {
  "subject_id": text,
  "revoked_at": uint,
  "reason": text,
  "cascade": "self_only" | "machine_and_dependents",
  "signature": bytes(64)
}
```

Pipeline:

1. Deduplicate by `event_id`.
2. Verify event signature.
3. Validate the revocation proof according to the household revocation
   contract.
4. Append to `CRLStore`.
5. If `subject_id` is an `m_id`, remove that machine from
   `HouseholdMembershipStore`.
6. Persist cursor after CRL and membership mutations commit.

The CRL append is idempotent. Subscribers receive each new revocation once.

## Cursor Persistence

Store the last applied cursor in UserDefaults because it is a non-secret resume
token. Persist it only after all side effects for the event commit.

On reconnect:

- resume from last applied cursor;
- drop duplicate event ids already applied;
- never reinsert an existing identical member;
- never remove a member twice.

## Diagnostics

Rejected events log only:

- severity;
- event id or hash;
- event type;
- sanitized reason enum.

Diagnostics must not include raw cert CBOR, private keys, APNS tokens, Tailscale
addresses, or full payload dumps.
