# Mac ↔ Linux admin host routing — Follow-up

Tracks the work to make the Mac UX fully functional against a paired
`.adminHost` server. Originated from PR #105 and partially overlaps issue
[#103](https://github.com/soyeht/soyeht-ios/issues/103).

## What PR #105 shipped

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

## What the issue #103 PR shipped (this branch)

The path-routing follow-up landed nine `.adminHost`-aware endpoints behind
a single registry, plus two iOS-side fallbacks for routes the admin host
does not expose yet.

- **Path resolver:** `ServerKind.path(for: Endpoint)` in
  `Packages/SoyehtCore/Sources/SoyehtCore/API/ServerKind+Endpoint.swift`
  is the single registry of kind-aware paths. Each call site delegates
  through `requirePath(_:for:operation:)` and surfaces
  `APIError.unsupportedOnServerKind` when the resolver returns `nil`.
- **Refactored call sites in `SoyehtAPIClient+Claws.swift`** (path stripping):
  - `getInstances(context:)` — engine `/api/v1/mobile/instances` ↔ admin `/api/v1/instances`
  - `getClaws(context:)` — engine `/api/v1/mobile/claws` ↔ admin `/api/v1/claws`
  - `getClawAvailability(name:context:)`
  - `installClaw(name:context:)` / `uninstallClaw(name:context:)`
  - `getInstanceStatus(id:context:)` — both paths kind-aware; decoder now
    unwraps the admin host's `{ instance: {...}, job: ... }` shape into
    the existing flat `InstanceStatusResponse`.
  - `createInstance(_:context:)` — both paths kind-aware; decoder now
    unwraps the admin host's `{ instance: {...}, job_id, message }` into
    the existing flat `CreateInstanceResponse`.
- **iOS-side fallbacks (no network) when kind=adminHost:**
  - `getResourceOptions(context:)` returns conservative defaults that
    match the admin backend's `CreateInstanceReq` validation envelope
    (1–4 CPU cores, 512–8192 MB RAM, 5–50 GB disk).
  - `getUsers(context:)` returns `[]`. UI should treat that as "no other
    users available; default to current user."
- **`SoyehtAPIClient.logout()`** delegates through the resolver:
  engine `/api/v1/mobile/logout`, admin `/api/v1/auth/logout`.
- **`validateSession()`** uses `kind.path(for: .sessionStatus)` instead
  of an inline switch.
- **Regression tests in `SoyehtAPIClientKindTests.swift`** pin the wire
  shape per kind for all nine endpoints + both fallback paths +
  dual-shape decoders. 21 tests, all green.

## Still open — admin backend gaps (theyos repo)

Two endpoints have iOS-side fallbacks because no admin-host route
exists. The fallbacks are correct under the admin backend's existing
validation envelope, but the Mac surfaces less information than the
engine flow does (no dynamic capacity, no user picker).

A follow-up PR in `theyos` should add:

1. **`GET /api/v1/resource-options`** (admin-authed, Cookie session).
   Returns the same `ResourceOptionsResponse` shape as
   `/api/v1/mobile/resource-options` (`{ cpuCores, ramMb, diskGb }`,
   each a `ResourceOption { min, max, default, disabled }`). Backing
   logic is identical — `compute_capacity_projection` + the same
   per-host fallbacks.
2. **`GET /api/v1/users`** (admin-authed, Cookie session). Returns
   `{ data: [{ id, username, role }] }` matching
   `/api/v1/mobile/users`. Same `list_users()` source.

When those routes land, remove the fallbacks in
`SoyehtAPIClient+Claws.swift` (the `guard let path = ...` blocks for
`.resourceOptions` and `.users`) and the corresponding test cases
(`resourceOptionsAdminKindReturnsFallbackWithoutNetwork`,
`usersAdminKindReturnsEmptyWithoutNetwork`).

## Mac UI follow-up (separate PR)

The Mac drawer-style `ClawDrawerViewController` (the sidebar that opens
from the "Claw Store…" menu) is the only Claw Store surface currently
wired in production. It is a flat list with inline `[install]` buttons
on uninstalled catalog rows — it does *not* expose uninstall buttons
on installed rows, nor a "Deploy" affordance for creating instances.

`ClawStoreWindowController` + `MacClawStoreRootView` + `MacClawDetailView`
exist in code and contain the missing flows (grid layout, tap-to-detail,
uninstall, deploy) but `@IBAction showStandaloneClawStore(_:)` has no
caller — no menu, no toolbar button, no command-palette entry binds to
it. So the standalone window is unreachable from the running app.

That means two of the kind-aware endpoints this PR adapts have no UI
consumer on the Mac side yet:

- `SoyehtAPIClient.uninstallClaw(name:context:)` — no UI surface
- `SoyehtAPIClient.createInstance(_:context:)` — no UI surface

Both are pinned by URLProtocol tests and share the same routing helper
(`requirePath(_:for:operation:)`) and path resolver
(`ServerKind.path(for:)`) as `installClaw`, which is exercised live by
the existing drawer install flow. So the API layer is ready; only the
Mac UI is missing.

The Mac Claw Store redesign is tracked as a separate follow-up PR. When
that lands it should:

1. Wire `showStandaloneClawStore(_:)` (or equivalent) into a reachable
   trigger — toolbar button, menu item, or command palette entry.
2. Surface uninstall on `MacClawDetailView` (already coded) so
   `uninstallClaw` has a consumer.
3. Surface deploy / "New instance from this claw" so `createInstance`
   has a consumer.
4. Re-run the E2E acceptance below end-to-end against `.adminHost`,
   including uninstall + deploy.

## Manual E2E acceptance — gate for marking #103 done

Run a fresh `SoyehtMac` build paired with an `.adminHost` `devs`:

1. Toolbar → Claw Store opens, catalog populates with `availability`
   projection on each item; no SPA fallback, no 401. **Verified
   2026-05-19**: 16+ claws rendered, tier metadata correct, install
   buttons present on `not installed` rows.
2. Click `[install]` on a tier=Catalog claw → server returns
   `HTTP 400 "claw type '<name>' is not installable yet (tier: Catalog)"`
   surfaced in UI. **Verified 2026-05-19**: confirms request reached
   `/api/v1/claws/<name>/install` (admin path), Cookie auth accepted,
   `handle_install_claw` rust handler executed, iOS decoded the error.
3. New conversation picker — Instance dropdown populates (or shows
   "No instances available" when the server has none). **Verified
   2026-05-19**: `GET /api/v1/instances → 200` with empty list (devs
   genuinely has zero instances at audit time).
4. Deploy a Claw with a non-default resource set →
   `POST /api/v1/instances` returns 202, status polling progresses
   through `provisioning_phase` updates, eventually flips to `active`.
   **Deferred**: depends on Mac UI follow-up (no deploy surface yet).
5. Open the deployed instance's pane — WS attach succeeds.
   **Deferred**: depends on Mac UI follow-up.
6. ⌘Q → relaunch → state preserved, instance list still populates.
7. Sign out (logout): server returns 204, local session cleared.
   **Deferred**: requires a non-destructive logout test pass; the
   `logoutAdminKindUsesAuthLogout` URLProtocol test covers the wire shape.

## Out of scope (handled elsewhere)

- Auth-header dispatch and WS upgrade headers (PR #105).
- iCloud / CloudKit sync paths.
- `continue-QR` engine-only handoff (already fenced on `.adminHost`).

## Open questions

- Should the admin host's `/api/v1/admin/*` namespace be exposed to the
  Mac at all, or only the user-scoped subset? Affects what gets surfaced
  in the Claw Store UI for non-admin sessions.
- Long-term: should `.adminHost` be the only Linux kind we support, or
  is a future `.engine`-on-Linux variant possible? Affects whether the
  switch arms stay binary or need a third case.
