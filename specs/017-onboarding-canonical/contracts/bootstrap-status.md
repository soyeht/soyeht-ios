# Contract — `GET /bootstrap/status`
<!-- mirror of theyos:005/contracts/bootstrap-status.md as of 6c78fe7 -->

**Feature**: 017-onboarding-canonical
**Date**: 2026-05-09
**Cross-repo mirror**: `theyos/specs/004-onboarding/contracts/bootstrap-status.md`

## Purpose

Allows Soyeht.app (Mac or iOS) to query the current lifecycle state of an engine instance, plus enough metadata to render install/welcome UX without further round-trips.

## Endpoint

`GET /bootstrap/status`

**Authentication**: none (public on `127.0.0.1:8091` and Tailscale interface; engine binds local-only by default, Tailnet exposure is per-config).

**Idempotent**: yes; safe to poll.

## Request

No body. No query params.

## Response (200 OK)

Content-Type: `application/cbor`

```
CBOR map:
{
  "v": 1,                                     // uint, version
  "state": <text enum>,                       // see BootstrapState
  "engine_version": "0.1.8",                  // text, semver
  "platform": "mac" | "linux",                // text enum
  "host_label": "Developer Mac",         // text, ≤96 bytes UTF-8 (Host.localizedName); empty for Linux v1
  "owner_display_name": "Sample Home" | null,   // text or null; null when state=uninitialized|ready_for_naming
  "device_count": 0..255,                     // uint; 0 means no moradores yet
  "hh_id": <uuid string> | null,              // null until POST /initialize succeeded
  "hh_pub": <33-byte bytes> | null            // SEC1 compressed P-256; null until POST /initialize succeeded
}
```

### `state` enum values

- `"uninitialized"` — engine just booted, no house yet, no key
- `"ready_for_naming"` — engine listeners up, awaiting `POST /bootstrap/initialize`
- `"named_awaiting_pair"` — house created with name + key, awaiting first morador
- `"ready"` — at least one morador paired
- `"recovering"` — restore flow in progress (out of scope this delivery; engine MUST emit this enum value but transitions into it are not implemented)

## Error envelope (4xx, 5xx)

Content-Type: `application/cbor`

```
{ "v": 1, "error": <text code>, "message": <text> | null }
```

### Error codes

- `"engine_initializing"` (503) — listeners not yet ready; client retries with backoff [0.5s, 1s, 2s, 4s].
- `"internal_error"` (500) — unspecified failure; do not retry beyond 1 attempt.

## CBOR encoding rules

- Deterministic per RFC 8949 §4.2.1 (lex-sorted map keys, smallest int representation).
- All keys are text; no integer-keyed maps.
- Unknown keys cause decode failure (fail-closed allowlist; consistent with existing `JoinRequestStagingClient` pattern from PR #75).

## Polling cadence

Mac app polls every 500ms while installer screen is visible (Cena MA3); falls back to exponential backoff [1s, 2s, 4s, 8s] with 30s cap on first 3 consecutive errors. Stop polling once `state ∈ {ready_for_naming, named_awaiting_pair, ready}`.

## Test fixtures

`Packages/SoyehtCore/Tests/SoyehtCoreTests/BootstrapStatusClientTests.swift` MUST cover:
- Decoding each state enum value
- `hh_pub` round-trip (encode→decode of 33 bytes)
- Unknown enum value rejected
- Non-CBOR Content-Type rejected
- 503 retry backoff schedule
