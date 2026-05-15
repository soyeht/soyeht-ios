---
id: multi-server-fanout
ids: ST-Q-MFAN-001..012
profile: standard
automation: auto
requires_device: true
requires_backend: both
destructive: false
cleanup_required: false
---

# Multi-Server Fan-Out (Server-Scoped API Client)

## Objective
Verify the home screen shows **every claw from every paired server** in a single aggregated list, and that every per-instance action routes to the server that owns the instance — without ever mutating `SessionStore.activeServerId` as a side effect.

Introduced in refactor **`fix/fonts` → server-scoped `SoyehtAPIClient`** (see `docs/issue-server-scoped-api-client.md`). Before this change, tapping a claw from a non-active server worked by flipping `activeServerId` globally, which had four real problems: race with background `loadInstances()`, observer leakage, cache mixing on cold start, and silent collision on identical `instance.id` across servers.

## Risk
- **P0** — Home screen shows only the active server's claws → aggregated fan-out broken.
- **P0** — Tapping a claw on server B triggers a request to server A → `ServerContext` not threaded; the race we're supposed to have fixed is back.
- **P1** — Cold start shows FQDN instead of server name under each card → per-server cache aggregation regressed.
- **P1** — Two servers with identical `instance.id` collapse into one row → `InstanceEntry.id` collision guard regressed.
- **P1** — Starting a deploy and opening ClawStore on server B mutates A's state → ClawStore context thread-through regressed.

## Preconditions
- Two backends running and paired:
  - Mac (localhost:8892) via `soyeht pair`
  - <backend-host> (`<host>.<tailnet>.ts.net`) via `ssh <host-2> 'soyeht pair'`
- Each server has **at least 2 active claws** (label them `test-qa-mfan-*` so cleanup is obvious).
- iOS app logged in, both servers listed in Settings > Servers, with any one of them as active.

## How to automate
- **Aggregate render**: open app fresh; `appium_screenshot` + XPath count of `InstanceList.instanceCard(*)` across accessibility tree.
- **Owning-server label**: read secondary text on each `InstanceList.instanceCard(*)` — should match the owning server's `name`, not the instance FQDN.
- **No activeServerId flip on tap**:
  1. Read `defaults read group.com.soyeht.mobile soyeht.activeServerId` before tap.
  2. Tap a claw from the **non-active** server.
  3. Read again right after the session sheet opens — value must be unchanged.
- **Owning-server routing**: after tapping a non-active-server claw, inspect the next outbound API request via `launch_app_logs_sim` filtered to `[request]` — the URL must match the owning server's host, not the active one.
- **Id collision**: rename two instances (one per server) to the same `container` by editing backend DB rows directly for this suite only; restore after run.
- **Cold-start cache**: quit + relaunch app; `appium_screenshot` within 300 ms of splash dismiss — no card should show a raw FQDN (`*.example.com`, `*.ts.net`) in the secondary line.

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MFAN-001 | Launch app with two paired servers, each having ≥2 claws | Home list shows the union of both servers' claws, count = `len(A) + len(B)` | P0 | Yes |
| ST-Q-MFAN-002 | Read the secondary line of each claw card | Secondary line shows the **owning server's name** (e.g. `<backend-host>`, `mac`), not the instance FQDN | P1 | Yes |
| ST-Q-MFAN-003 | With server A active, tap a claw whose owning server is B | Session sheet opens with that claw's workspaces; `activeServerId` remains A | P0 | Yes |
| ST-Q-MFAN-004 | Confirm workspace fetch (opening the sheet above) hit server B | Captured request URL host == B's host; `Authorization` header == B's token | P0 | Yes — inspect logs / proxy |
| ST-Q-MFAN-005 | Context-menu on a claw whose owning server is B → `stop` | Instance on B transitions to `stopped`; A's instances untouched; `activeServerId` unchanged | P1 | Yes |
| ST-Q-MFAN-006 | Context-menu on a claw whose owning server is B → `restart` | Instance on B returns to `active`; A's list unaffected | P1 | Yes |
| ST-Q-MFAN-007 | Pull-to-refresh the home list | Both servers are re-fanned-out in parallel; list count stable; no server's rows disappear even if one server is mid-refresh | P1 | Yes |
| ST-Q-MFAN-008 | Force-quit app, relaunch (no network) | Home list renders immediately from cache, per-server names present under each card (no FQDN flash) | P1 | Yes |
| ST-Q-MFAN-009 | Both servers expose instances with the **same `instance.id`** | Both rows render as distinct entries (disambiguated by `InstanceEntry.id = "<serverId>:<instanceId>"`). Tap either one routes to the correct host | P1 | Yes — use staged fixture |
| ST-Q-MFAN-010 | Open "claw store" from home while on server A | Store loads with A's install context; installing a claw hits A's `/api/v1/mobile/claws/{name}/install` | P1 | Yes |
| ST-Q-MFAN-011 | Start a deploy via "claw store" picking server B, then immediately switch active server back to A | Deploy finishes on B, `ClawDeployMonitor` polls B's `/api/v1/mobile/instances/{id}/status`, and a theyos://instance/<id> deep-link from the Live Activity widget routes correctly | P1 | Yes — monitor logs for 3 min |
| ST-Q-MFAN-012 | One server offline (kill backend) + pull-to-refresh | Online server's claws remain; offline server's last-cached claws remain; error banner surfaces the offline server's error only | P2 | Yes |

## Acceptance (must all pass)

- MFAN-001 green: **every** claw from **every** paired server visible on the home screen, in a single list. This is the contract the refactor exists to deliver.
- MFAN-003 + MFAN-004 green: tapping a non-active-server claw does **not** mutate `activeServerId`, and the next API request routes to the correct host.
- MFAN-008 green: cold-start cache is per-server self-consistent (no FQDN flash).
- MFAN-009 green: `instance.id` collisions across servers are disambiguated (no silent row drop).

## Cleanup
- Delete any `test-qa-mfan-*` instances created during the run.
- Restore any DB rows mutated for MFAN-009.

## Cross-references
- Unit tests: `SoyehtAPIClientTests.twoServersSameInstanceId_doNotCollide`, `SoyehtAPIClientTests.requestViaContextB_doesNotLeakServerA`.
- Adjacent domain: [`multi-server.md`](multi-server.md) covers pair/switch/delete/logout isolation. This file covers the aggregated-list contract the refactor introduces.
- Issue: `docs/issue-server-scoped-api-client.md`.
