# Refactor: make SoyehtAPIClient server-scoped instead of active-server-scoped

**Status:** open
**Area:** iOS / SoyehtAPIClient
**Priority:** tech debt — ship-blocking for any future multi-server feature

## Context

`InstanceListView` aggregates claws from every paired server (see
`InstanceListView.loadInstances` fan-out introduced on the `fix/fonts`
branch). To route per-instance API calls to the right host, the view
currently mutates shared state by flipping `SessionStore.activeServerId`
before each tap / action:

```swift
private func switchActiveServer(for instance: SoyehtInstance) {
    guard let serverId = serverIdByInstanceId[instance.id],
          store.activeServerId != serverId else { return }
    store.setActiveServer(id: serverId)
}
```

This works as an MVP but is a code smell: `SoyehtAPIClient` still reads
`store.apiHost` / `store.sessionToken` globally, so every surface that
observes the active server (widgets, Live Activity, NavigationState
cache, background refresh) sees the value flipping whenever the user
touches a claw from a non-active server.

## Problems

1. **Action at a distance.** `store.activeServer` changes as a side
   effect of a tap, affecting code paths far from the list (widgets,
   session cache).
2. **Race condition.** If a background `loadInstances()` finishes between
   the `switchActiveServer` call and `listWorkspaces(container:)`
   dispatch, the workspaces request can land on the wrong host.
3. **Cache mixing.** `store.saveInstances(aggregated)` now caches a mix
   of every server's claws into storage previously scoped per-server.
   Cold-start flashes FQDN instead of server name until fan-out
   completes.
4. **No per-server error surfacing.** Fan-out only keeps `lastError`;
   when multiple servers fail with different reasons, the user sees only
   one.
5. **Potential `instance.id` collisions across servers** —
   `serverIdByInstanceId` silently overwrites if two servers ever emit
   the same id.

## Proposed fix

Make every per-instance API method explicitly server-scoped:

```swift
func listWorkspaces(server: PairedServer, token: String, container: String) ...
func instanceAction(server: PairedServer, token: String, id: String, action: ...) ...
func buildWebSocketURL(server: PairedServer, token: String, container: String, sessionId: String) ...
// etc.
```

Introduce a `ServerContext` value type carrying `(server, token)` to
avoid threading two parameters through every call site.

Change `InstanceListView` to carry the owning server alongside each
instance (either a wrapper `InstanceEntry(instance:, server:)` or a
`serverByInstanceId` map keyed by server id) and pass the context down
to `SessionListSheet`, `SessionStore.saveInstances(_:serverId:)`, etc.

Keep `SessionStore.activeServerId` as a **UX preference** (last-visited
server, used only to decide which server the QR / Add flow targets), not
a routing signal.

## Out of scope

- Backend changes — endpoints already respond per host, no API contract
  change needed.
- Migrating MacTerminal — this issue is iOS only.

## Acceptance

- No call to `store.apiHost` or `store.sessionToken` inside
  `SoyehtAPIClient` request-building methods.
- Tapping a claw from server B while active server is A does **not**
  mutate `activeServerId`.
- `store.saveInstances(_:)` is either removed or refactored to be
  per-server.
- Existing tests pass; new tests cover (a) two servers with the same
  `instance.id` not colliding, (b) a request to server B not leaking
  tokens from server A.

## Touch points (search anchors)

- `TerminalApp/Soyeht/SoyehtAPIClient.swift` — `authenticatedRequest`,
  `makeAuthenticatedURLRequest`, every per-instance method
- `TerminalApp/Soyeht/InstanceListView.swift` —
  `switchActiveServer(for:)`, `loadInstances()`,
  `performInstanceAction(_:action:)`
- `TerminalApp/Soyeht/SessionStore.swift` — `apiHost`, `sessionToken`,
  `activeServerId`, `saveInstances(_:)`, `loadInstances()`
