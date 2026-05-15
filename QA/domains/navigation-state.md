---
id: navigation-state
ids: ST-Q-NAV-001..002
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Navigation State Restoration

## Objective
Verify that saved navigation state uses instance/session IDs matching new format, and that expiration logic works.

## Risk
Saved state uses IDs that must match new snake_case format. If format mismatch, restoration fails silently.

## Preconditions
- Connected to server with active instance

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-NAV-001 | Open a terminal, kill app | On relaunch, app navigates directly to last terminal | P1 | Yes |
| ST-Q-NAV-002 | Wait 25+ hours, reopen | State expired. App shows instance list instead | P2 | Yes |
