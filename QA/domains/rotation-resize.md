---
id: rotation-resize
ids: ST-Q-ROTX-001..007
profile: release
automation: manual
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Rotation & Terminal Resize

## Objective
Verify terminal sends correct resize message via WebSocket when device rotates, and that tmux/shell output re-renders correctly at new dimensions.

## Risk
SwiftTerm calls `sizeChanged` which sends WebSocket resize JSON. If message dropped (WebSocket briefly reconnecting), tmux doesn't resize and output wraps at wrong column count permanently.

## Preconditions
- Connected to an instance terminal

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-ROTX-001 | Open terminal in portrait. Run `tput cols; tput lines` | Shows portrait dimensions (e.g., 45 cols, 80 lines) | P2 | Manual |
| ST-Q-ROTX-002 | Rotate to landscape | Terminal re-renders with wider columns. No text corruption | P2 | Manual |
| ST-Q-ROTX-003 | In landscape, run `tput cols; tput lines` | Shows landscape dimensions. Values differ from portrait | P2 | Manual |
| ST-Q-ROTX-004 | Rotate back to portrait | Terminal re-renders at original dimensions | P2 | Manual |
| ST-Q-ROTX-005 | Run `top` in portrait, rotate to landscape | TUI app re-renders correctly at new dimensions | P2 | Manual |
| ST-Q-ROTX-006 | Run `vim` with file, rotate | Vim re-renders. No status bar corruption. Wrapping adjusts | P2 | Manual |
| ST-Q-ROTX-007 | Rotate while output actively streaming | Output continues at new width. No dropped data. No crash | P2 | Manual |
