---
id: mac-auth
ids: ST-Q-MAUTH-001..007
profile: quick
automation: assisted
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Auth & Session

## Objective
Verify authentication on macOS via host+token text fields (no QR scanner), URL scheme deep link, session persistence across relaunches, and Keychain sharing with the iOS app.

## Risk
- Login sheet not shown on first launch if NSDocument lifecycle interferes with AppDelegate auth check
- URL scheme handler fires before the window is ready → sheet has no parent window
- `keychainService = "com.soyeht.mobile"` on macOS must match iOS so tokens are shared; any mismatch silently breaks cross-device auto-login

## Preconditions
- macOS app built from latest commit
- At least one Soyeht server reachable (localhost or <backend-host>)
- Pair token available: run `soyeht pair` on target server

## How to automate
- **Login flow**: `mcp__XcodeBuildMCP__build_run_sim` for macOS target, then `type_text` into NSTextField via accessibility identifier
- **URL scheme**: `open "theyos://pair?token=X&host=Y"` via Bash → triggers `AppDelegate.application(_:open:)`
- **Session check**: Kill and relaunch the app process; verify it goes to instance list (not login)
- **Keychain verify**: iOS app builds next to macOS; check both list the same server after macOS pair

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MAUTH-001 | Fresh install (no keychain entries): launch macOS app | Login sheet appears immediately. No "Open" file dialog. No QR scanner | P0 | Yes |
| ST-Q-MAUTH-002 | Enter valid host + valid token → click Connect | Sheet dismisses. Instance list visible. No crash or decode error | P0 | Yes |
| ST-Q-MAUTH-003 | Enter valid host + **invalid** token → click Connect | Inline error label appears below fields. Sheet stays open. No crash | P1 | Yes |
| ST-Q-MAUTH-004 | After MAUTH-002: quit app (Cmd+Q) and relaunch | App goes straight to instance list (session restored). Login sheet not shown | P0 | Yes |
| ST-Q-MAUTH-005 | Open `theyos://pair?token=X&host=Y` URL from Safari/Terminal | Login sheet pre-fills host and token fields; clicking Connect works | P1 | Assisted |
| ST-Q-MAUTH-006 | Pair macOS with server A via login sheet. Open iOS app on same physical Mac (simulator) | Each app has its own local keychain — they do NOT auto-share tokens (`kSecAttrSynchronizable` is not set in SessionStore). iOS app shows QR scanner, not instance list. This confirms correct isolation | P2 | Yes |
| ST-Q-MAUTH-007 | Logout from server: File > Logout (or Settings) | Keychain entry for that server removed. Login sheet reappears. Other paired servers unaffected | P1 | Assisted |

## Out of Scope
- Multi-server management on macOS (see mac-cross-device.md)
- Token expiry edge cases (server-side)
