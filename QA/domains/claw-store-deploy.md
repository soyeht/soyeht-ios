---
id: claw-store-deploy
ids: ST-Q-CLAW-001..012
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: true
cleanup_required: true
---

# Claw Store & Deploy

## Objective
Verify claw catalog loading (Phase 1 envelope, Phase 2 snake_case), install/uninstall, and full deploy flow including resource options and user list.

## Risk
If `installed_at`, `job_id` aren't decoded, install status wrong. If `data` key not read, claw list empty. Resource options decode failure breaks deploy form.

## Preconditions
- Admin credentials
- At least 1 installed claw and 1 uninstalled claw

## Fixtures
- Deploy creates instances named `test-qa-deploy-*`

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-CLAW-001 | Open Claw Store from instance list | Catalog loads. Featured + trending sections visible | P1 | Yes |
| ST-Q-CLAW-002 | Verify claw details | Each shows: name, description, language, install status | P2 | Yes |
| ST-Q-CLAW-003 | Tap a claw for details | Detail view with description, reviews, install button | P2 | Yes |
| ST-Q-CLAW-004 | Install a claw (admin) | Install starts. Progress indicator. Status changes to "Ready" | P1 | Yes |
| ST-Q-CLAW-005 | Uninstall a claw (admin) | Status changes to "Not Installed" | P1 | Yes |
| ST-Q-CLAW-006 | Verify installed/not-installed states | Correct status display for ready/not_installed/installing | P2 | Yes |
| ST-Q-CLAW-007 | Open deploy form from Claw Detail | Setup form loads with resource sliders (CPU, RAM, Disk) | P1 | Yes |
| ST-Q-CLAW-008 | Verify resource limits | Sliders show correct min/max/default from server | P2 | Yes |
| ST-Q-CLAW-009 | Verify user list (admin) | User dropdown loads with correct usernames and roles | P2 | Yes |
| ST-Q-CLAW-010 | Fill form and deploy | Instance creation starts. Monitor shows provisioning progress | P1 | Yes |
| ST-Q-CLAW-011 | Monitor deployment | Live Activity or polling shows status updates | P2 | Yes |
| ST-Q-CLAW-012 | Deployment completes | New instance in list with "active" status | P1 | Yes |

## Cleanup
- Delete `test-qa-deploy-*` instances after testing

## Related Runs
- [2026-04-06 Live Activity Deploy](../runs/2026-04-06-live-activity-deploy/report.md) — 4/5 PASS
