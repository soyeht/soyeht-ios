# Claw Install Target (iOS)

The iOS Claw Store speaks **one** vocabulary: a Claw is installed on a
specific `Server`. PR-3 introduces `ClawInstallTarget` as the single
UI-facing type and pushes the "which wire path?" decision behind a
resolver.

## The two layers

```
UI / routes  ─────►  ClawInstallTarget(serverID: Server.ID)
                          │
                          ▼
                ClawInstallTargetResolver.resolve(...)
                          │
                          ├── .server(ServerContext)              [preferred]
                          ├── .householdEndpoint(serverID, URL)    [Mac PoP]
                          └── .unavailable(.missingContext|.unknownServer)
                          │
                          ▼
SoyehtCore Claw APIs  ──►  ClawAPITarget.server(ctx)
                         | .householdEndpoint(URL)
                         | .household
```

The resolver is the **only** iOS file allowed to mention
`ClawAPITarget.household`. `ClawRouteUsageTests` enforces this with a
source-slice grep — any other file that touches `.household` fails the
test.

## Resolver rules

The resolver inspects `ServerRegistry.shared` and
`SessionStore.shared` (read-only) and decides:

1. **`SessionStore.context(for: serverID)` returns a `ServerContext`** →
   `.server(ctx)`. This is the preferred path. Catalog browse, install,
   uninstall, and Deploy all work normally via the per-server endpoints
   (`/api/v1/mobile/...` for engine kind, `/api/v1/...` for admin host).

2. **No context AND the server is a Mac with a reachable household
   endpoint** → `.householdEndpoint(serverID, endpoint)`. Catalog
   browse and install/uninstall route to that Mac's own
   `/api/v1/household/claws*` routes using owner PoP auth. Instance
   create/list/status/actions/workspaces/terminal use the same selected
   Mac household endpoint. The endpoint, not an implicit aggregate,
   identifies the selected Mac.

3. **Anything else** → `.unavailable(...)`. The Claw Store renders
   `MacClawUnavailableView` with copy that tells the user Soyeht cannot
   reach that Mac's Claw endpoint yet. The picker pre-flights this —
   disabled rows carry the same copy, so the user does not tap-and-discover.

`ClawAPITarget.household` remains for macOS and legacy single-endpoint
flows, but iOS no longer uses it for multi-Mac routing. Pair-machine can
still grow a per-Mac `ServerContext` later; when it does, those Macs will
prefer `.server(ctx)` automatically.

## Cardinality at the home Claw Store button

| `ServerRegistry.count` | Behavior |
| --- | --- |
| 0 | Button hidden. The empty-state CTA already promotes pairing. |
| 1 | Push `.store(serverId:)` directly. Resolver decides. |
| ≥ 2 | Push `.serverPicker`. Picker lists every server. Macs without a legacy token are still selectable when they have a PoP household endpoint. |

## What PR-3 does **not** fix

Target routing and guest-image readiness are separate. The Claw Store UI
now *knows which Mac* it's targeting, but the engine on that Mac may
still need guest-image preparation before install succeeds. The iOS gate
renders that as "Setup needed on this Mac" / "Preparing" / "Failed"
rather than as a routing error.

PR-3 also did not touch:

- The pair-machine UI flow (Add Mac).
- The guest image build pipeline.
- The DMG / Release workflow.
- Recovery (R0/R1).
- macOS Claw Store view (`MacClawStoreRootView`) — only adds an
  explicit `.serverPicker: EmptyView()` ramp for switch exhaustiveness.

## Source-slice tests

```bash
# Forbidden in iOS:
grep -rn "ClawRoute\.householdStore\|ClawRoute\.householdDetail\|\.householdStore\b\|\.householdDetail\b" \
  TerminalApp/Soyeht --include="*.swift"
# Expected: 0 matches

# ClawAPITarget.household only in the resolver:
grep -rn "ClawAPITarget\.household\|target:\s*\.household" \
  TerminalApp/Soyeht --include="*.swift" \
  | grep -v "ClawInstallTargetResolver.swift"
# Expected: 0 matches

# Engine pin for the current release train:
cat scripts/theyos-engine.version
# Expected: 0.1.21
```

Run `ClawRouteUsageTests` to enforce the first two as part of CI.
