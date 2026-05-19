# Mac ↔ Linux admin host routing — Follow-up

Tracks the remaining work to make the Mac UX fully functional against a
paired `.adminHost` server. Originated from PR #105 and partially overlaps
issue [#103](https://github.com/soyeht/soyeht-ios/issues/103).

## What PR #105 already shipped

- `PairedServer.kind` field (`.engine` / `.adminHost`), backward-compatible
  Codable for legacy records.
- Auth-header rule on `ServerKind.applyAuth(to:token:)`:
  - `.engine` → `Authorization: Bearer <token>`
  - `.adminHost` → `Cookie: soyeht_session=<token>`
  Used by `applyServerAuth`, `authenticatedRequest(path:context:)`, and
  the inline-body `createInstance`. Wire shape pinned by URLProtocol tests.
- `resolveInstancesPath()` for the single endpoint that already had
  divergent paths between engine (`/api/v1/mobile/instances`) and admin
  host (`/api/v1/instances`).
- `AddLinuxServerSheet` pairing flow (SSH bootstrap → HTTPS login via
  `tailscale serve` → Cookie session) + `HTTPCookie` parser.
- WebSocket attach: cookie value rides a `Cookie:` header instead of
  the URL query for `.adminHost` (`buildWebSocketAttachment`).
- UI gating: `PaneHeaderView.isQRHandoffEnabled` flips off when the
  active server kind is `.adminHost`.
- Welcome flow: `autoPairExistingSoyeht` short-circuits when a server is
  already paired, so `AddLinuxServerSheet` lands on the main window
  without auto-pairing the local engine on top.

## What still 401s against `.adminHost`

The Claw Store and instance-listing endpoints are still hard-coded to the
engine-prefixed `/api/v1/mobile/*` namespace. The admin host's SPA fallback
returns either 401 or 200+HTML for those paths, so the Mac shows an empty
listing rather than an error. Empirically observed during PR #105 E2E:

- `getClaws(context:)` → `GET /api/v1/mobile/claws` → 401
- `getInstances(context:)` → `GET /api/v1/mobile/instances` → 401
- `getClawAvailability(name:context:)` → `GET /api/v1/mobile/claws/{name}/availability`
- `installClaw(name:context:)` → `POST /api/v1/mobile/claws/{name}/install`
- `uninstallClaw(name:context:)` → `POST /api/v1/mobile/claws/{name}/uninstall`
- `getResourceOptions(context:)` → `GET /api/v1/mobile/resource-options`
- `getUsers(context:)` → `GET /api/v1/mobile/users`
- `getInstanceStatus(id:context:)` → `GET /api/v1/mobile/instances/{id}/status`
- `createInstance(_:context:)` → `POST /api/v1/mobile/instances`
- Legacy `getInstances()` (no context) — `resolveInstancesPath()` already
  switches on kind, but only one endpoint of many.

The methods that already use the unprefixed shape — `instanceAction(id:action:context:)`,
`getInstance(id:context:)` — happen to work on both kinds.

## Work items

### 1. Audit the admin backend's route table

Before changing any path on the Mac, enumerate the admin host's actual
`/api/v1/*` routes in `~/Documents/theyos/admin/rust/server-rs/src/`. The
naive assumption is "drop the `/mobile/` prefix" but several endpoints
may not exist on the admin host at all, or live under a different name
(`/api/v1/admin/*`, `/api/v1/store/*`, etc.). Result of this audit: a
mapping table `(engine path) → (adminHost path, or "not available")`.

### 2. Generalize `resolveInstancesPath()` to all divergent endpoints

Either:
- a centralized `kindAwarePath(_ enginePath: String, on: ServerKind)`
  helper that strips/rewrites the prefix, or
- per-endpoint `resolveXxxPath()` methods.

The first scales as more endpoints diverge; the second documents intent
better per endpoint. Pick after the audit.

### 3. Reconcile response shapes

Some engine endpoints wrap the payload (`{ data: [...] }`); some admin
endpoints return the array directly (or vice versa). `getInstances` and
`getUsers` already try both shapes — generalize that pattern, or add a
typed wrapper that decodes both transparently.

### 4. Surface clear errors when an endpoint doesn't exist

`unexpectedHtmlResponse` already catches the SPA-fallback case for HTML
content type. Add equivalent guard for "200 + JSON with shape that
doesn't match any expected wrapper" so silent empty listings don't
masquerade as success.

### 5. Pin every adapted endpoint with a `URLProtocol`-based test

Mirror the pattern from `SoyehtAPIClientKindTests`. Assert both:
- correct path per kind (e.g. `/api/v1/mobile/claws` for engine,
  `/api/v1/claws` or whatever the audit found for adminHost), and
- header shape per kind (already covered by `ServerKind.applyAuth`).

### 6. Manual E2E acceptance — the gap PR #105 left open

After steps 1–5 land, the Mac running against a `.adminHost`-paired
`devs` should:

1. Open the Claw Store from the toolbar — listing populates, no SPA
   fallback, no 401.
2. Open the new-conversation Instance dropdown — instances list
   populates (not "No instances available").
3. Deploy a Claw — `createInstance` returns 200, the instance shows up
   in the home grid.
4. Open the deployed instance's pane — WS attach succeeds (this is
   already validated by PR #105 against `hermes-agent`, but re-confirm
   end-to-end through the new dropdown).

## Out of scope (handled elsewhere)

- Auth-header dispatch and WS upgrade headers (PR #105).
- `iCloud`/CloudKit sync paths.
- The `continue-QR` engine-only handoff (already 410-fenced on `.adminHost`).

## Open questions

- Should the admin host's `/api/v1/admin/*` namespace be exposed to the
  Mac at all, or only the user-scoped subset? Affects what gets surfaced
  in the Claw Store UI for non-admin sessions.
- The `Connected Servers` window probe at `ConnectedServersWindowController`
  already branches on kind for `/mobile/status` vs `/instances` — should
  that probe also reach into the new endpoints once they exist?
- Long-term: should `.adminHost` be the only Linux kind we support, or
  is a future `.engine`-on-Linux variant possible? Affects whether the
  switch arms stay binary or need a third case.
