# Contract: Owner Events Long-Poll

Co-versioned with theyos:
`/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/owner-events.md`.

The owner-events stream delivers owner-targeted join requests to the iPhone.
It is the authoritative data path. APNS is only a wakeup tickle.

## Request

```http
GET /api/v1/household/owner-events?since=<cursor>
Authorization: Soyeht-PoP ...
Accept: application/cbor
```

Authentication is Soyeht-PoP under the owner PersonCert with the standard
replay window.

`since` is base64url-no-pad of the deterministic CBOR unsigned integer cursor.
The first poll uses cursor zero. The client treats the cursor as opaque except
for using the same encoder required by the theyos contract.

## Responses

Events available:

```http
200 OK
Content-Type: application/cbor
```

```cbor
OwnerEventsResponse = {
  "v": 1,
  "events": [OwnerEvent],
  "next_cursor": uint
}
```

Timeout:

```http
204 No Content
```

No body. Cursor does not change.

Failure:

```http
401 Unauthorized
Content-Type: application/cbor
```

```cbor
{ "v": 1, "error": "unauthenticated" }
```

JSON error bodies are a protocol violation on Phase 3 endpoints.

## OwnerEvent

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

Before using payload content, the iPhone verifies `signature` under the
issuer MachineCert chained to `hh_pub`.

## Accepted Types

### `join-request`

```cbor
payload = {
  "join_request_cbor": bytes,
  "fingerprint": text,
  "expiry": uint
}
```

iPhone pipeline:

1. Verify outer `OwnerEvent.signature`.
2. Decode `payload.join_request_cbor` as canonical `JoinRequest`.
3. Reconstruct `JoinChallenge`.
4. Verify `JoinRequest.challenge_sig` under `m_pub`.
5. Derive fingerprint from `BLAKE3-256(m_pub)`.
6. Compare joined words byte-equal with `payload.fingerprint`.
7. Build `JoinRequestEnvelope` using `expiry` as `ttlUnix`.
8. Enqueue into `JoinRequestQueue`.
9. Persist cursor only after enqueue succeeds.

Fingerprint mismatch maps to `MachineJoinError.derivationDrift`.

### `machine-joined`

```cbor
payload = {
  "m_pub": bytes(33),
  "m_id": text,
  "hostname": text,
  "joined_at": uint
}
```

The iPhone may use this to clear pending cards by `m_pub`. Membership mutation
is still driven by snapshot/gossip MachineCert validation.

### `join-cancelled`

```cbor
payload = {
  "m_pub": bytes(33),
  "reason": text
}
```

The iPhone clears any matching pending card. The reason is diagnostic only.

## Cursor Policy

Cursor advance is a local acknowledgement. Store the new cursor only after all
accepted events in the response have committed their local side effects. If any
event fails validation, the cursor remains at the last applied value and the
error is surfaced through `MachineJoinError`.

Duplicate events after reconnect must not double-enqueue. The queue idempotency
key is `(hh_id, m_pub, nonce)`.

## Long-Poll Lifecycle

- Foreground app: keep one active long-poll request.
- `204`: immediately re-poll with the same cursor.
- Transport drop: exponential reconnect with jitter.
- Session clear: cancel the in-flight request and discard local coordinator
  state.
- Background: suspend foreground loop. APNS wake calls one fetch attempt and
  schedules the normal foreground loop when the app becomes active.

Server timeout is 45 seconds by default and never more than 60 seconds.

## APNS Fence

The APNS body is not owner-event data. The canonical theyos tickle body is:

```json
{"aps":{"content-available":1}}
```

The iPhone handler must not branch on any household-derived APNS field. If any
extra payload key appears beyond the APNS-required `aps.content-available`
shape, the handler records an integrity error and still fetches no content from
the push itself.

## Unknown Token Recovery

Current theyos Phase 3 does not define a distinct `unknown-token` owner-events
error. Token recovery is therefore idempotent re-registration on next foreground
using `POST /api/v1/household/owner-device/push-token`. If theyos later returns
a typed CBOR error `unknown-token`, the iPhone maps it to the same
re-registration path without user action.
