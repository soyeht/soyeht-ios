# ServerStore v2-read flip — operational runbook (Track D, D3c GO)

This is the operator procedure for turning on the **canonical v2 read path** for the
`ServerStore` migration. It is the final, deliberately-manual step of Track D: the
code (D1→D3c) is merged and inert, and this flip is an **operational decision** that
must follow a clean live dry-run. It is intentionally NOT auto-fired by any code.

## What the flip actually changes

`ServerRegistry` reads the server inventory through
`ServerInventoryWriter.loadCanonical(...)`, gated by the UserDefaults flag
`ServerStore.v2ReadEnabledKey` (`"com.soyeht.serverstore.v2ReadEnabled"`, default
**OFF**).

- **Flag OFF (today):** `loadCanonical` is byte-for-byte identical to `load()` — the
  legacy v1 read. The v2 mirror is still dual-written on every mutation, but never
  read. This is the shipped, proven state.
- **Flag ON:** `loadCanonical` serves the **v2 projection** ONLY when BOTH hold:
  1. `MigrationReadiness.isReadyToFlip` (`shadowClean && migrationCompleted`), and
  2. runtime equivalence: `Set(v2-projected) == Set(v1)`.

  If either fails it **falls back to v1**. So flipping the flag is *safe by
  construction*: a not-ready device keeps reading v1; it never serves a divergent or
  credential-less v2.

## Preconditions (must be true before flipping)

1. **D3c merged** on the build under test (it is, on local `main`).
2. **Migration completed** on the device: the app has launched and run a full
   migrate/reconcile cycle, so `migrationCompleted == true`. This happens
   automatically on normal launches once D-track code is present.
3. **Shadow clean**: `ServerStoreShadowComparer` reports no credential/orphan
   mismatches (`shadowClean == true`, `blockingCategories` empty). This is what the
   dry-run confirms.

## Dry-run validation (go/no-go)

The readiness verdict comes from `ServerInventoryWriter.migrationDryRunReadiness(...)`,
which returns a `MigrationReadiness { shadowClean, migrationCompleted,
blockingCategories, isReadyToFlip }`.

**Observability note:** today this verdict is computed *internally* by the gated read;
the writer does not log (D1/D2 forbid logging credential state). To make the dry-run
externally visible on a device, the supported option is a **DEBUG-only diagnostic in
`ServerRegistry`** (which already logs neutral counts) that logs
`migrationDryRunReadiness`'s `isReadyToFlip` + `blockingCategories.count` (NO ids, NO
credential values) at startup. Add that diagnostic first if you want an explicit
green light before flipping; it is a small, review-gated slice. Without it, the flip
is still safe (the gate auto-falls-back), but you won't *see* whether v2 is actually
being served vs silently falling back to v1.

**Go criterion:** `isReadyToFlip == true` AND `blockingCategories` empty on the target
device(s).

## The flip

On a **Dev build** first (never the shipping app), set the flag:

```
defaults write <app-domain> com.soyeht.serverstore.v2ReadEnabled -bool true
```

…or via whatever debug-settings affordance the build exposes for
`ServerStore.v2ReadEnabledKey`. Relaunch so `ServerRegistry` re-reads through the
gate.

## Post-flip validation

1. Inventory renders identically (same servers, same order, same active selection).
2. No credential loss: paired Macs still connect; tokens/pairing secrets intact
   (the D1/D2 preservation + the `projected == v1` gate guarantee this, but verify on
   the device).
3. If a DEBUG readiness diagnostic is present, confirm it logs `isReadyToFlip=true`
   (i.e. v2 is genuinely served, not falling back).

## Rollback (instant, safe)

```
defaults write <app-domain> com.soyeht.serverstore.v2ReadEnabled -bool false
```

Relaunch. `loadCanonical` returns to the v1 read immediately. There is no data
migration to undo — the v2 mirror is a parallel projection, and v1 remains the
persisted authority for reads while the flag is off.

## Why this is operator-gated, not code-gated

D3c deliberately ships the flag default-OFF with no code path that sets it. The flip
is a judgment call about a specific device population after a clean dry-run, made by
the operator (Caio) — exactly so a code change can never silently flip the read
authority for everyone. See `docs/claw-store-score-plan.md` (Track D) and the D3c
guard `test_serverRegistryReadsThroughGatedLoadCanonical`.
