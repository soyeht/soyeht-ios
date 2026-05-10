# Contract — `POST /bootstrap/initialize`
<!-- mirror of theyos:005/contracts/bootstrap-initialize.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Cross-repo mirror**: `theyos/specs/004-onboarding/contracts/bootstrap-initialize.md`

## Purpose

Mints the house identity (P-256 keypair in Secure Enclave on Mac, in keyring on Linux) and persists the chosen name. Idempotent only via `claim_token` (Caso B); without one, repeated calls fail.

## Endpoint

`POST /bootstrap/initialize`

**Authentication**: none. Engine MUST be in state `uninitialized` or `ready_for_naming` to accept; any other state returns 409.

**Why no auth**: at this point no identity exists. The first POST creates one.

## Request

Content-Type: `application/cbor`

```
{
  "v": 1,
  "name": <text>,                             // 1..32 UTF-8 chars; no '/', ':', '\\', '\0'
  "claim_token": <32-byte bytes> | null       // optional; ties initialize to a SetupInvitation (Caso B)
}
```

## Response (200 OK)

Content-Type: `application/cbor`

```
{
  "v": 1,
  "hh_id": <uuid string>,
  "hh_pub": <33-byte bytes>,                  // SEC1 compressed P-256
  "pair_qr_uri": <text>                       // soyeht://pair-device?... format (existing PairMachineQR shape)
}
```

After this response is sent, engine state transitions to `named_awaiting_pair`.

## Error envelope (4xx, 5xx)

```
{ "v": 1, "error": <text code>, "message": <text> | null }
```

### Error codes

- `"name_too_short"` (400) — name is empty or whitespace-only after trim
- `"name_too_long"` (400) — name >32 UTF-8 chars
- `"name_invalid_chars"` (400) — contains forbidden filesystem chars
- `"already_initialized"` (409) — engine state is not `uninitialized` or `ready_for_naming`
- `"claim_token_invalid"` (401) — `claim_token` doesn't match any active SetupInvitation
- `"claim_token_expired"` (401) — token TTL exceeded
- `"keychain_acl_denied"` (500) — SE keypair gen failed (typically biometry not enrolled)
- `"internal_error"` (500)

## Atomicity

The handler MUST:
1. Validate name + token shape
2. Generate P-256 keypair in Secure Enclave (Mac) or keyring (Linux)
3. Persist (name, hh_pub, hh_priv_ref, created_at, claim_token_ref) atomically
4. Transition state to `named_awaiting_pair`
5. Build `pair_qr_uri` with new `hh_pub`
6. Return response

If any step fails after key gen, key MUST be deleted from SE/keyring before returning error (no orphan keys).

## CBOR rules

Same as bootstrap-status.md. Fail-closed allowlist on unknown keys.

## Test fixtures

`BootstrapInitializeClientTests.swift`:
- Happy path: valid name → 200 with `hh_pub` parseable
- Each error code path
- claim_token + name combination round-trip
- Idempotency: 2nd call without token returns 409
- Idempotency: 2nd call with same token returns 200 (same hh_pub) (Caso B retry safety)
