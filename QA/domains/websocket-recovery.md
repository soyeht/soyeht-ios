---
id: websocket-recovery
ids: ST-Q-WSRC-001..010
profile: full
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# WebSocket Recovery & Commander/Mirror Handoff

## Objective
Verify WebSocket reconnection (Wi-Fi loss, background/foreground), exponential backoff, commander/mirror mode transitions via closeCode 4000, and Take Command flow.

## Risk
If `appWillEnterForeground` reconnects without checking `isInMirrorMode`, app fights other device for commander in a loop. If backoff isn't capped, app hammers server. If resize message not sent after reconnect, terminal shows garbled columns.

## Preconditions
- Connected to an instance terminal (commander mode)
- For mirror tests: open the same terminal in a web browser (use Chrome DevTools MCP to navigate to the terminal URL)

## How to automate
- **Background/foreground**: `appium_mobile_background_app(seconds: N)` — Appium handles this natively
- **Mirror mode trigger**: Open same terminal in Chrome via `mcp__chrome-devtools__navigate_page` to the backend web UI. The second connection triggers closeCode 4000 on mobile.
- **Take Command**: Tap the "Take Command" button via Appium after mirror mode activates
- **WiFi toggle**: Ask user to toggle WiFi manually (Control Center). Print "Toggle WiFi OFF now" and wait.
- **Kill + relaunch**: `appium_terminate_app` + `appium_activate_app`

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-WSRC-001 | Open terminal. Ask user: "Toggle WiFi OFF now" | Terminal shows disconnect indicator. No crash | P0 | Assisted (WiFi toggle) |
| ST-Q-WSRC-002 | Ask user: "Toggle WiFi ON now" (within 30s) | WebSocket reconnects (up to 3 attempts). Terminal resumes | P0 | Assisted (WiFi toggle) |
| ST-Q-WSRC-003 | `appium_mobile_background_app(seconds: 30)` | Terminal reconnects via foreground recovery. Resize message sent | P0 | Yes |
| ST-Q-WSRC-004 | `appium_mobile_background_app(seconds: 300)` | WebSocket reconnects. Previous tmux session state visible | P0 | Yes |
| ST-Q-WSRC-005 | Ask user: "Toggle WiFi OFF and wait 30s" | "Connection failed" state. No infinite retry. Manual retry available | P1 | Assisted (WiFi toggle) |
| ST-Q-WSRC-006 | After WSRC-005, ask "Toggle WiFi ON", then tap retry | Terminal connects. Previous session visible | P1 | Assisted (WiFi toggle) |
| ST-Q-WSRC-007 | Open same terminal in Chrome DevTools MCP (web browser) | Mobile receives closeCode 4000. Switches to mirror mode (read-only) | P1 | Yes — use Chrome DevTools MCP |
| ST-Q-WSRC-008 | In mirror mode, verify input blocked | Keyboard input does not send. Mirror indicator visible | P1 | Yes |
| ST-Q-WSRC-009 | In mirror mode, tap "Take Command" | Mobile takes commander role. Input works | P1 | Yes |
| ST-Q-WSRC-010 | In mirror mode, `appium_mobile_background_app(seconds: 10)`, return | App does NOT auto-reconnect as commander (respects isInMirrorMode) | P1 | Yes |
