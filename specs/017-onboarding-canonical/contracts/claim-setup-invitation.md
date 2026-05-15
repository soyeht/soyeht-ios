# Contract — `POST /bootstrap/claim-setup-invitation`
<!-- mirror of theyos:005/contracts/claim-setup-invitation.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Cross-repo mirror**: `theyos/specs/004-onboarding/contracts/claim-setup-invitation.md`

## Purpose

Mac (post-install) calls this on its OWN engine to register an iPhone-issued setup invitation. The engine stores the token + iPhone APNs token + display name suggestion, allowing the next `POST /bootstrap/initialize` to use them (skipping the house-naming UI on Mac in favor of the iPhone-driven flow).

## Endpoint

`POST /bootstrap/claim-setup-invitation`

**Authentication**: none (engine state must be `uninitialized` or `ready_for_naming`).

## Request

Content-Type: `application/cbor`

```
{
  "v": 1,
  "token": <32-byte bytes>,                   // from Bonjour TXT
  "owner_display_name": <text> | null,        // mirrored from TXT
  "iphone_apns_token": <≤32-byte bytes> | null
}
```

## Response (200 OK)

```
{
  "v": 1,
  "accepted_at": <uint>                       // unix seconds; engine timestamp
}
```

The engine persists the token + APNs binding for the upcoming `POST /bootstrap/initialize`. Only the **first** claim per engine instance succeeds; subsequent claims with different tokens return `409 already_claimed`.

## Error envelope

- `"already_initialized"` (409) — state ≠ uninitialized|ready_for_naming
- `"already_claimed"` (409) — engine already has a pending claim (different token)
- `"token_invalid_length"` (400) — not 32 bytes
- `"internal_error"` (500)

## Side effects

- Engine state stays at `uninitialized` or `ready_for_naming` (claim is preparatory; doesn't transition state).
- Engine schedules an APNs push for when `POST /bootstrap/initialize` lands and `state=named_awaiting_pair` is reached: payload `{type: "house_created", hh_id: "...", owner_display_name: "..."}`.

## Test fixtures

`ClaimSetupInvitationClientTests.swift`:
- Happy path: claim → subsequent /initialize uses owner_display_name as default
- 2nd claim same token: returns 200 (idempotent same token)
- 2nd claim different token: returns 409
- After /initialize: claim attempt returns 409
- token round-trip (32 bytes preserved)
