---
id: multi-server
ids: ST-Q-MSRV-001..012
profile: full
automation: auto
requires_device: true
requires_backend: both
destructive: false
cleanup_required: false
---

# Multi-Server Isolation

## Objective
Verify multi-server add/switch/delete AND that actions on server A don't corrupt server B's state. Covers auth isolation, token expiration, navigation restore, and commander claims per server.

## Risk
Keychain stores tokens as `[serverId: token]` dict. If logout clears whole dict instead of one key, all servers lose auth. Commander claims can leak across if not keyed by serverId.

## Preconditions
- Two backends running: Mac (`localhost:8892`) + <backend-host> (`https://<host>.<tailnet>.ts.net`)
- Pair tokens: `soyeht pair` on Mac, `ssh devs 'soyeht pair'` on <backend-host>

## How to automate
- **Pair second server**: Generate token with `soyeht pair` or `ssh devs 'soyeht pair'`, then `appium_deep_link`
- **Switch server**: Navigate to server list via Appium, tap the other server
- **Delete server**: Swipe action on server row
- **Logout**: Navigate to server list, swipe/logout on target server
- **Terminal on A, switch to B**: Tap instance, wait for terminal, go back, tap server list, tap B
- **Kill + relaunch**: `appium_terminate_app` + `appium_activate_app`
- **Token expiry (MSRV-007/008)**: At gate preflight, pair Mac with a short-lived token (`soyeht pair -d 1m`). By the time Phase 5 runs, the Mac token will have expired. Switch to <backend-host> (should work fine), then switch back to Mac (should show re-auth prompt). This tests cross-server token isolation without waiting.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MSRV-001 | Pair with <backend-host> via `appium_deep_link` | Second server in Settings > Servers | P1 | Yes |
| ST-Q-MSRV-002 | Switch active server to <backend-host> | Instance list refreshes with <backend-host> instances | P1 | Yes |
| ST-Q-MSRV-003 | Delete <backend-host> server (swipe) | Server removed. Switches to Mac or QR scanner | P1 | Yes |
| ST-Q-MSRV-004 | Pair both. Logout from Mac server | Mac token removed. <backend-host> still works. List shows <backend-host> | P1 | Yes |
| ST-Q-MSRV-005 | After MSRV-004, re-pair with Mac | Both functional. <backend-host> data untouched | P1 | Yes |
| ST-Q-MSRV-006 | Open terminal on Mac, switch to <backend-host> | WS to Mac disconnects. List shows <backend-host>. No zombie WS | P1 | Yes |
| ST-Q-MSRV-007 | Mac paired with short-lived token (1m) from preflight — now expired. App on <backend-host> | <backend-host> works. No alerts about Mac until switch | P1 | Yes — use expired preflight token |
| ST-Q-MSRV-008 | Switch to Mac (expired token) | Re-auth prompt for Mac only. <backend-host> unaffected | P1 | Yes — tap Mac server, verify re-auth |
| ST-Q-MSRV-009 | Nav state on Mac terminal. Kill app. Relaunch | Does NOT restore terminal if Mac offline. Shows list or error | P1 | Yes — terminate + activate |
| ST-Q-MSRV-010 | Delete the only remaining server | App → QR scanner. No crash from nil activeServer | P0 | Yes |
| ST-Q-MSRV-011 | Delete inactive server (not being viewed) | Inactive removed. Current server unaffected | P1 | Yes |
| ST-Q-MSRV-012 | Both servers have instances with identical names | Correct server context. Tap goes to correct server | P2 | Yes |
