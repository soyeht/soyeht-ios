# Contract: APNS Registration

Co-versioned with theyos:
`/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/push-token-register.md`
and `contracts/owner-events.md`.

This contract supersedes older local task text that referenced
`/apns-register`, `/apns-deregister`, and APNS body `{"v":1}`.

## Token Registration / Rotation

```http
POST /api/v1/household/owner-device/push-token
Authorization: Soyeht-PoP ...
Content-Type: application/cbor
```

Body:

```cbor
OwnerDevicePushTokenRegister = {
  "v": 1,
  "platform": "ios",
  "push_token": bytes
}
```

Response:

```cbor
OwnerDevicePushTokenAck = {
  "v": 1,
  "updated_at": uint
}
```

Failure is the generic Phase 3 CBOR error shape:

```cbor
{ "v": 1, "error": "unauthenticated" }
```

The PoP header carries the owner `p_id`; the body does not include `p_id` or
`hh_id`.

## iPhone Lifecycle

- Register on first post-pairing launch when APNS is enabled.
- Register again when iOS provides a different device token.
- Skip network calls when the token is unchanged.
- Re-register on foreground if local state indicates registration is unknown
  or if a future theyos `unknown-token` error is observed.
- On APNS-disabled setting, suppress registration and run foreground-only
  owner-events long-poll.

## Deregistration

Current theyos Phase 3 does not define a deregistration endpoint. Session clear
therefore has these iPhone-side effects:

- delete local cached push-token registration state;
- stop responding to household-specific owner-events coordinators;
- stop future registration attempts unless a new household session is paired.

If theyos later adds an explicit deregistration route, it must be added here
before implementing a network deregister call in iSoyehtTerm.

## Opaque APNS Tickle

Server-side APNS dispatch body is exactly these UTF-8 bytes:

```json
{"aps":{"content-available":1}}
```

Headers:

- `apns-push-type: background`
- `apns-priority: 5`
- `apns-topic: <Soyeht iPhone bundle id>`
- `apns-expiration: <now + 300>`

No `alert`, `badge`, `sound`, `mutable-content`, `category`, household id,
event cursor, hostname, fingerprint, or machine id is allowed in the push body.

The iPhone treats APNS arrival as a tickle only. It always fetches authoritative
event content over `GET /api/v1/household/owner-events`.

## Payload Invariant Test

The iPhone test harness must assert byte equality with:

```text
b"{\"aps\":{\"content-available\":1}}"
```

Any length difference, whitespace, additional JSON key, or old `{"v":1}` body
fails the invariant.

## Privacy Contract

The push token is a household-private artifact. The iPhone sends it only to a
household member through Soyeht-PoP. Household members send it only to Apple's
APNS endpoint as the HTTP/2 device token target.
