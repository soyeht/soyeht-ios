---
id: terminal-websocket
ids: ST-Q-TERM-001..006
profile: quick
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Terminal & WebSocket Connection

## Objective
Verify terminal connection, WebSocket communication, commander mode, and workspace display after API standardization (Phase 2 snake_case).

## Risk
If `session_id` or `display_name` aren't decoded from the workspace response, terminal might fail to connect or show wrong session name.

## Preconditions
- At least 1 online instance with terminal access

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TERM-001 | Tap an online instance | Terminal opens, WebSocket connects, shell prompt visible | P0 | Yes |
| ST-Q-TERM-002 | Type a command (e.g. `ls`) | Output appears in terminal. No garbled text | P0 | Yes |
| ST-Q-TERM-003 | Workspace name displays | Tab/header shows workspace display name (not UUID) | P2 | Yes |
| ST-Q-TERM-004 | Check commander mode | Terminal shows you're in "Commander" mode | P1 | Yes |
| ST-Q-TERM-005 | Disconnect (go back) | Returns to instance list cleanly. No crash | P1 | Yes |
| ST-Q-TERM-006 | Reconnect to same instance | Terminal reconnects, previous session state visible | P1 | Yes |
