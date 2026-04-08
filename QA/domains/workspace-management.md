---
id: workspace-management
ids: ST-Q-WORK-001..005
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: true
cleanup_required: true
---

# Workspace Management

## Objective
Verify workspace CRUD after API standardization (Phase 1 envelope, Phase 2 snake_case, Phase 3 204 for rename/delete).

## Risk
Rename and delete return 204 (empty body). If app tries to parse JSON from empty response, it crashes. Create returns `{"workspace": {...}}` (unchanged).

## Preconditions
- Connected to an instance with terminal access

## Fixtures
- Workspaces created during test should be named `test-qa-ws-*`

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-WORK-001 | Create a new workspace | New workspace appears in list. Terminal connects to it | P1 | Yes |
| ST-Q-WORK-002 | Create workspace with custom name | Workspace shows the custom name entered | P2 | Yes |
| ST-Q-WORK-003 | Rename a workspace | Name updates immediately in UI. No error alert | P1 | Yes |
| ST-Q-WORK-004 | Delete a workspace (swipe or button) | Workspace disappears. Confirmation dialog first | P1 | Yes |
| ST-Q-WORK-005 | List workspaces after create/delete | Count is correct. No phantom entries | P1 | Yes |

## Cleanup
- Delete `test-qa-ws-*` workspaces after testing
