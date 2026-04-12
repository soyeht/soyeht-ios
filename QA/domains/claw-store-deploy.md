---
id: claw-store-deploy
ids: ST-Q-CLAW-001..020
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: true
cleanup_required: true
---

# Claw Store & Deploy

## Objective
Verify claw catalog loading (Phase 1 envelope), install/uninstall with real progress, full deploy flow with resource options and user list, AND the new ClawAvailability projection contract introduced in the backend refactor: per-claw availability polling, byte/percent progress bar, two-axis state model (install vs create), installed-but-blocked rendering with reasons, and uninstall-still-valid behavior when blocked.

## Risk
- If `availability` field decode fails, claw catalog is empty (fail-fast behavior — was a silent fallback before).
- If `isInstalled` and `canCreate` collapse into one axis, installed-but-blocked claws disappear from `installedCount` and lose the uninstall affordance.
- If polling reads legacy `status` instead of `installState.isTransient`, uninstalling state never updates.
- If `.unknown` install/overall state is treated as transient instead of terminal, polling spins forever on contract drift.
- If progress bar reads `claw.status == "installing"` (legacy), it never appears under the new contract.

## Preconditions
- Admin credentials
- At least 1 installed claw, 1 uninstalled claw, 1 installable claw on a server with cold path ready
- (For installed-but-blocked tests) admin SSH access to the dev server to toggle maintenance / drop base rootfs

## Fixtures
- Deploy creates instances named `test-qa-deploy-*`
- For blocked-state tests: server with `maintenance_blocked=true` OR missing base rootfs

## Test Cases

### Catalog & Detail (basic load)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-CLAW-001 | Open Claw Store from instance list | Catalog loads. Featured + trending sections visible | P1 | Yes |
| ST-Q-CLAW-002 | Verify claw card details | Each shows: name, description, language, install state badge | P2 | Yes |
| ST-Q-CLAW-003 | Tap a claw for details | Detail view with description, install state, install/deploy buttons | P2 | Yes |

### Install / Uninstall + real progress (NEW)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-CLAW-004 | Install a claw (admin) | Install starts. Card shows real progress bar with bytes (`X / Y MB`) and percent updating every ~2s | P1 | Yes |
| ST-Q-CLAW-005 | Open detail view of installing claw | Detail also renders the same progress bar (driven by `getClawAvailability` endpoint) | P1 | Yes |
| ST-Q-CLAW-006 | Wait for install to finish | Status flips to "installed", "deploy >" button appears, polling stops | P1 | Yes |
| ST-Q-CLAW-007 | Uninstall an installed claw | Status shows "uninstalling..." (amber), no actions available, polling tracks the transition | P1 | Yes |
| ST-Q-CLAW-008 | Wait for uninstall to finish | Status flips to "not installed", install button reappears | P1 | Yes |

### Two-axis state model (installed-but-blocked) — NEW

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-CLAW-009 | Force `maintenance_blocked=true` on server with installed claws, refresh store | Installed claws render `installed • blocked` badge in **amber** (not hidden, not as "unavailable"). `installedCount` footer still includes them. | P1 | Manual setup |
| ST-Q-CLAW-010 | Open detail of an installed-but-blocked claw | Status label = `installed • blocked`. Reasons block visible with `server is syncing artifacts — retry in Ns`. Uninstall button **still present**. Deploy button **hidden**. | P1 | Manual setup |
| ST-Q-CLAW-011 | Tap uninstall on installed-but-blocked claw | Uninstall starts (transition to `.uninstalling`), no error | P1 | Manual setup |
| ST-Q-CLAW-012 | Drop base rootfs on server, refresh store | Installed claws show `installed • blocked` with reason `server is missing the base image — contact admin` | P2 | Manual setup |
| ST-Q-CLAW-013 | Verify `installedCount` footer | Footer count includes blocked AND uninstalling claws — only excludes truly notInstalled / installing / installFailed / unknown | P1 | Manual |

### Deploy flow

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-CLAW-014 | Open deploy form from a creatable (`.installed`) claw | Setup form loads with resource sliders | P1 | Yes |
| ST-Q-CLAW-015 | Verify resource limits | Sliders show correct min/max/default from server | P2 | Yes |
| ST-Q-CLAW-016 | Verify user list (admin) | User dropdown loads with correct usernames and roles | P2 | Yes |
| ST-Q-CLAW-017 | Fill form and deploy | Instance creation starts. Monitor shows provisioning progress | P1 | Yes |
| ST-Q-CLAW-018 | Monitor deployment | Live Activity or polling shows status updates | P2 | Yes |
| ST-Q-CLAW-019 | Deployment completes | New instance in list with "active" status | P1 | Yes |
| ST-Q-CLAW-020 | Try to deploy an installed-but-blocked claw | Deploy button NOT shown in detail view (this is the bug the refactor fixes — used to show button + 400) | P1 | Manual setup |

## New a11y identifiers (Appium locators)

- `soyeht.clawStore.clawCard.{name}.progressBar`
- `soyeht.clawStore.clawCard.{name}.progressPercent`
- `soyeht.clawDetail.progressBar`
- `soyeht.clawDetail.progressPercent`
- `soyeht.clawDetail.reasonsBlock`
- `soyeht.clawDetail.reasonRow.{index}`
- `soyeht.clawDetail.installButton` (existed)
- `soyeht.clawDetail.uninstallButton` (existed; now appears in BOTH `.installed` and `.installedButBlocked` branches)
- `soyeht.clawDetail.deployButton` (existed; appears ONLY in `.installed` branch — never in `.installedButBlocked`)

## Cleanup
- Delete `test-qa-deploy-*` instances after testing
- Re-enable maintenance mode / restore base rootfs if test ST-Q-CLAW-009/010/012 toggled them

## Related Runs
- [2026-04-06 Live Activity Deploy](../runs/2026-04-06-live-activity-deploy/report.md) — 4/5 PASS
