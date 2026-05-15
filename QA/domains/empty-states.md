---
id: empty-states
ids: ST-Q-EMPT-001..007
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Empty States & Zero-Data Paths

## Objective
Verify UI behavior when data is missing: zero instances, zero claws, zero workspaces, no active tmux session.

## Risk
Empty arrays from `{"data": []}` might pass decoding but trigger index-out-of-bounds if UI assumes at least 1 item. The "$ connect" button can get permanently disabled if loading never completes.

## Preconditions
- Server with configurable state (can stop all instances, etc.)

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-EMPT-001 | Connect to server with zero instances | Empty state message (not blank screen, not spinner forever) | P1 | Yes |
| ST-Q-EMPT-002 | In empty instance state, verify CTA | "Deploy" or Claw Store navigation available | P2 | Yes |
| ST-Q-EMPT-003 | Stop all instances. View list | All show as stopped. Online count = 0. No crash | P1 | Yes |
| ST-Q-EMPT-004 | Open instance with no active tmux session | Shows "no active tmux session" with "$ connect" button | P1 | Yes |
| ST-Q-EMPT-005 | Tap "$ connect" in empty tmux state | New workspace created and terminal connects | P1 | Yes |
| ST-Q-EMPT-006 | Delete all workspaces, then view instance | Shows empty workspace list or auto-creates default | P1 | Yes |
| ST-Q-EMPT-007 | View Claw Store with zero claws installed | Shows available claws with "Install" buttons | P2 | Yes |
