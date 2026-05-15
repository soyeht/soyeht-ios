---
id: mac-soyeht-terminal
ids: ST-Q-MWST-001..009
profile: quick
automation: assisted
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Soyeht WebSocket Terminal

## Objective
Verify the macOS WebSocket terminal (AppKit port of WebSocketTerminalView): connection, input/output, resize, reconnection via `NSApplication.didBecomeActiveNotification`, sleep/wake recovery, commander mode, and clean disconnection.

## Risk
- `window?.makeFirstResponder(self)` not called in `connect()` → keyboard input doesn't go to terminal
- `NSApplication.didBecomeActiveNotification` (instead of iOS's `UIApplication.willEnterForegroundNotification`) not registered → no foreground reconnect after Mac wakes from sleep
- `sendResize` JSON not sent after reconnect → server thinks terminal is still old size → garbled output
- `NSWorkspace.shared.open(url)` not used for link opening → URLs silently fail on macOS

## Preconditions
- Logged in, at least one online instance with terminal capability
- Instance's WebSocket URL reachable from Mac

## How to automate
- **Connect**: Use instance picker (see mac-dev-workflow.md), then observe terminal area
- **Type + read**: `mcp__XcodeBuildMCP__type_text` + `screenshot`
- **Simulate background**: Switch to another app for N seconds, return
- **Sleep/wake**: Manual (close laptop lid); or use `pmset sleepnow` + wake after N seconds
- **Mirror mode**: Open same terminal URL in Chrome via `mcp__chrome-devtools__navigate_page`
- **Verify WS closed**: Check server logs or use Chrome DevTools network tab to confirm connection count drops after tab close

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MWST-001 | Open a Soyeht instance tab | WebSocket connects, shell prompt visible. First responder is terminal (typing goes to shell) | P0 | Yes |
| ST-Q-MWST-002 | Type `echo hello` + Return | Output `hello` appears. No garbled text. No echo of control sequences | P0 | Yes |
| ST-Q-MWST-003 | Drag window edge to resize → type `tput cols` | Server receives resize JSON. `tput cols` matches new visual column count | P0 | Assisted |
| ST-Q-MWST-004 | Switch to another app (e.g., Finder) for 30s, return to app | macOS does NOT kill the app (unlike iOS background). WS **stays connected** — terminal is immediately responsive. `didBecomeActiveNotification` fires but no reconnect needed (state is `.open`) | P0 | Yes |
| ST-Q-MWST-005 | Sleep Mac 5+ minutes (close lid or `pmset sleepnow`), wake | WS drops on sleep. `didBecomeActiveNotification` fires on wake → WS reconnects. Previous tmux session state visible. Resize message sent | P1 | Assisted |
| ST-Q-MWST-006 | Open same Soyeht instance in Chrome (backend web UI) | macOS app receives closeCode 4000 → enters mirror mode (input blocked). No crash | P1 | Yes — Chrome DevTools MCP |
| ST-Q-MWST-007 | In mirror mode from MWST-006: type in macOS terminal | No keystrokes sent to server. Mirror indicator visible | P1 | Yes |
| ST-Q-MWST-008 | Click "Take Command" (macOS equivalent) after MWST-006 | macOS reclaims commander role. Input works. Chrome session enters mirror | P1 | Assisted |
| ST-Q-MWST-009 | Close the Soyeht tab (Cmd+W) | WebSocket closes cleanly (server shows 0 connections for that session). No crash | P1 | Yes |

## Notes
- "Mirror mode" on macOS: the UI should show a read-only indicator (banner or title suffix). Exact UI is TBD during implementation — test should be updated once design is confirmed.
- Link-click test (cmd+click URL in terminal → NSWorkspace.shared.open): out of scope for initial gate; add to `full` profile once implemented.
