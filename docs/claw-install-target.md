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
                          ├── .householdFallback(serverID)         [temporary]
                          └── .unavailable(.missingContext|.unknownServer)
                          │
                          ▼
SoyehtCore Claw APIs  ──►  ClawAPITarget.server(ctx) | .household
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

2. **No context AND the server is a Mac AND `ServerRegistry.count == 1`** →
   `.householdFallback(serverID)`. Catalog browse and install/uninstall
   route via `ClawAPITarget.household` (PoP-signed against the founder
   Mac's engine). **Deploy is never offered** in this resolution because
   `createInstance` requires a `ServerContext`.

3. **Anything else** → `.unavailable(...)`. The Claw Store renders
   `MacClawUnavailableView` with copy that tells the user this Mac
   needs a Soyeht update. The picker pre-flights this — disabled rows
   carry the same copy, so the user does not tap-and-discover.

The `.householdFallback` branch is **temporary compatibility code**.

When pair-machine generates a per-Mac `ServerContext` (a token in
`SessionStore.server_tokens`), every Mac becomes a proper `.server`
target and the fallback branch can be deleted. The corresponding
multi-Mac case stops collapsing to `.unavailable(.missingContext)` —
every Mac without a context becomes an actionable "update needed"
state, exactly the same as today's multi-Mac branch. There is no
*permanent* design dependency on the household aggregate.

Tracking: follow-up issue `pr3-fallback-removal`.

## Cardinality at the home Claw Store button

| `ServerRegistry.count` | Behavior |
| --- | --- |
| 0 | Button hidden. The empty-state CTA already promotes pairing. |
| 1 | Push `.store(serverId:)` directly. Resolver decides. |
| ≥ 2 | Push `.serverPicker`. Picker lists every server, disables rows that resolve to `.unavailable(.missingContext)`. |

## What PR-3 does **not** fix

PR-3 corrects target/routing — nothing else. After PR-3 lands, install
on a Mac can still fail with `base image not ready` or equivalent
until the guest-image preparation PR lands. The Claw Store UI now
*knows which Mac* it's targeting, but the engine on that Mac may still
need work before install succeeds. That is a separate scope.

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
# Expected: 0.1.19
```

Run `ClawRouteUsageTests` to enforce the first two as part of CI.
