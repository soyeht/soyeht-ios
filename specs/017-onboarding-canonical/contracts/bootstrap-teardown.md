# Contract — `POST /bootstrap/teardown`
<!-- mirror of theyos:005/contracts/bootstrap-teardown.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Cross-repo mirror**: `theyos/specs/004-onboarding/contracts/bootstrap-teardown.md`

## Purpose

Wipes house state and returns engine to `uninitialized`. Backs FR-061 ("Recomeçar do zero") and the corrupted-install reinstall path (FR-062).

## Endpoint

`POST /bootstrap/teardown`

**Authentication**: PoP-signed by current `hh_priv` when state ∈ `{named_awaiting_pair, ready, recovering}`. None when state ∈ `{uninitialized, ready_for_naming}` (no key exists yet).

## Request

Content-Type: `application/cbor`

```
{
  "v": 1,
  "confirm": "WIPE_HOUSE",                    // text constant; must match exactly
  "wipe_keychain": true | false               // delete hh_priv from SE/keyring; default true
}
```

The `confirm` constant guards against accidental teardowns from buggy clients.

## Response (200 OK)

```
{ "v": 1 }
```

State transitions to `uninitialized`. All persisted house state removed (rows wiped, keychain entry deleted if `wipe_keychain=true`).

## Error envelope

- `"confirm_mismatch"` (400) — `confirm` ≠ `"WIPE_HOUSE"`
- `"unauthorized"` (401) — PoP signature invalid (when required)
- `"internal_error"` (500)

## Side effects

- Bonjour `_soyeht._tcp.` un-published (or re-published as `state=uninitialized`)
- LaunchAgent NOT unregistered by engine (app-side decision via `SMAppService.unregister()`)
- APNs device tokens cleared (no future "Sample Home te chamou" pushes)
