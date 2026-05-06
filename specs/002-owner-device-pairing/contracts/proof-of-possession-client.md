# Contract: Proof-of-Possession Client Request

## Header

For household-scoped authenticated requests, the app sends:

```http
Authorization: Soyeht-PoP v1:<p_id>:<unix_seconds>:<signature_b64url>
```

It MUST NOT send `Authorization: Bearer ...` to household-scoped operations.

## Signing Context

The signature is 64-byte raw P-256 ECDSA over deterministic CBOR:

```cbor
{
  "v": 1,
  "method": "GET",
  "path_and_query": "/api/v1/household/snapshot",
  "timestamp": 1714972800,
  "body_hash": h'...'
}
```

`body_hash` is BLAKE3-256 over exact request body bytes, or over the empty byte string when there is no body.

## Client Preconditions

Before signing, the app MUST have:

- active `ActiveHouseholdState`
- local OwnerPersonIdentity key reference
- locally valid PersonCert
- local caveat allowing the requested household action

If any precondition fails, the app blocks the request locally and renders recoverable UI state.

## Test Requirements

- Signed request contains `Soyeht-PoP`.
- Signed request does not contain `Bearer`.
- Changing method, path/query, timestamp, or body changes the signed context.
- Missing cert or invalid caveat prevents request construction.
