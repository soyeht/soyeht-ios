---
id: deep-links
ids: ST-Q-DEEP-001..011
profile: full
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Deep Links

## Objective
Verify all deep link flows: `theyos://pair`, `theyos://connect`, `theyos://invite`. Cold launch, warm launch, invalid tokens, expired tokens, deduplication.

## Risk
Cold launch stores URL in `pendingDeepLink` (SceneDelegate); if not consumed, pairing never triggers. Invite saves `redeemResponse.server.host` which can differ from deep link host.

## Preconditions
- Valid pair token from `soyeht pair`
- Invite token from backend API: `curl -X POST http://localhost:8892/api/v1/invites -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"instance_id":"<id>"}'`
- Ability to open URLs from Safari/Notes on device

## How to generate tokens
- **Pair token**: `soyeht pair` → extracts `token` from the deep link output
- **Expired token trick**: Generate a token with `soyeht pair` at the START of the gate run. By the time Phase 5 runs (~20min later), the 15-minute token will have expired. Use it for DEEP-003.
- **Invite token**: POST to `/api/v1/invites` with a valid session token and instance_id
- **Cold launch**: Use `appium_terminate_app` then `appium_deep_link` — this exercises the SceneDelegate `connectionOptions.urlContexts` code path

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-DEEP-001 | `appium_terminate_app`, then `appium_deep_link` with valid pair token | App launches cold, pairing completes, instance list appears | P0 | Yes — use terminate + deep_link |
| ST-Q-DEEP-002 | App in foreground, `appium_deep_link` with valid pair token | App receives link, shows pairing flow without crash/duplicate | P0 | Yes |
| ST-Q-DEEP-003 | Use the token generated at gate start (now expired after ~20min) | Clear error message (token expired). No hang or blank screen | P1 | Yes — use token from preflight |
| ST-Q-DEEP-004 | Use consumed token again | Error (token already consumed). No silent failure | P1 | Yes |
| ST-Q-DEEP-005 | Open `theyos://pair?host=Y&name=Z` (missing token) | App ignores link or shows validation error. No crash | P2 | Yes |
| ST-Q-DEEP-006 | Open `theyos://pair?token=X` (missing host) | App ignores link or shows validation error. No crash | P2 | Yes |
| ST-Q-DEEP-007 | Open `https://example.com` (wrong scheme) | App does NOT handle this link. No crash | P3 | Yes |
| ST-Q-DEEP-008 | Generate pair token with `soyeht pair`, use `appium_deep_link` with `theyos://connect?token=X&host=Y` | App connects to specific instance terminal directly | P1 | Yes — generate token first |
| ST-Q-DEEP-009 | Create invite via API, use `appium_deep_link` with `theyos://invite?token=X&host=Y` | Invite redeemed. Server added with `role: user` | P1 | Yes — create invite via curl |
| ST-Q-DEEP-010 | Invite where backend returns different host than link's host | App uses server-returned host for all subsequent API calls | P1 | Yes — compare hosts after redeem |
| ST-Q-DEEP-011 | Open same deep link twice within 1 second | Dedup prevents double processing. Only one pairing attempt | P1 | Yes |
