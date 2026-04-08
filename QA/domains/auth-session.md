---
id: auth-session
ids: ST-Q-AUTH-001..005
profile: quick
automation: auto
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
---

# Auth & Session

## Objective
Verify authentication, session persistence, and server pairing after API standardization (Phase 2 snake_case + Phase 3 204).

## Risk
If `session_token` or `expires_at` fields aren't decoded correctly from the auth response, pairing will fail silently or crash.

## Preconditions
- Backend running latest code
- iOS app built from latest commit
- QR code or pair token available

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-AUTH-001 | Fresh install: Open app | Splash screen (2s), then QR scanner | P0 | Yes |
| ST-Q-AUTH-002 | Scan QR code from server pairing page | App transitions to instance list. No crash, no decode error | P0 | Yes |
| ST-Q-AUTH-003 | Kill and reopen app | App restores session (goes to instance list, NOT QR scanner) | P0 | Yes |
| ST-Q-AUTH-004 | Background app 5 minutes, return | Session still valid, no re-auth required | P1 | Yes |
| ST-Q-AUTH-005 | Go to Settings > Servers | Paired server appears with correct name and host | P2 | Yes |

## Out of Scope
- Multi-server pairing (see multi-server.md)
- Token expiration edge cases (see error-handling.md)
