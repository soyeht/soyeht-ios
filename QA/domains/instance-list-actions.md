---
id: instance-list-actions
ids: ST-Q-INST-001..009
profile: quick
automation: auto
requires_device: true
requires_backend: mac
destructive: true
cleanup_required: true
---

# Instance List & Actions

## Objective
Verify instance list loading (Phase 1 envelope), display (Phase 2 snake_case), and instance actions (Phase 3 204, Phase 4 dedicated endpoints).

## Risk
If `data` key isn't read correctly, list will be empty. If action endpoints use old URLs, server returns 404. If 204 empty body is parsed as JSON, app crashes.

## Preconditions
- At least 1 active instance on server
- Admin credentials

## Fixtures
- Actions that stop/restart/rebuild/delete use only `test-qa-*` instances

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-INST-001 | View instance list after login | All instances appear with correct names, status, claw type tags | P0 | Yes |
| ST-Q-INST-002 | Pull down to refresh | List reloads, no crash. Count correct | P1 | Yes |
| ST-Q-INST-003 | Verify instance details | Each shows: name, container, claw type tag, online/offline status | P2 | Yes |
| ST-Q-INST-004 | Instance with `status: "active"` | Shows as online (green indicator) | P2 | Yes |
| ST-Q-INST-005 | Instance with `status: "stopped"` | Shows as offline (gray indicator) | P2 | Yes |
| ST-Q-INST-006 | Stop a running instance | Status changes to "stopped". No error alert | P1 | Yes |
| ST-Q-INST-007 | Restart a stopped instance | Status changes to "active". Terminal accessible again | P1 | Yes |
| ST-Q-INST-008 | Rebuild an instance | Goes through provisioning, returns to "active" | P1 | Yes |
| ST-Q-INST-009 | Delete an instance | Disappears from list. Confirmation dialog first | P1 | Yes |

## Cleanup
- Delete any `test-qa-*` instances created during testing
