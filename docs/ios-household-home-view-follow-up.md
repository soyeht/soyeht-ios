# iOS HouseholdHomeView Follow-Up

## Context

`HouseholdHomeView` currently appears when the iOS app has an active household
but does not yet have a local Mac pairing saved in `PairedMacsStore`.

That state can happen after delegated iPhone pairing, reinstall recovery, or a
partial local-pairing handoff. The screen was useful as a technical host for
household approval overlays, but it is not a good product destination:

- it exposes technical household identifiers
- it does not show the user's Mac-first home experience
- it has no obvious route back to the main app surface
- it duplicates responsibilities that `InstanceListView` already covers

## Product Direction To Study

For a future PR, evaluate removing `HouseholdHomeView` from normal navigation.
The likely target behavior:

1. If a household and local Mac pairing both exist, open `InstanceListView`.
2. If a household exists but local Mac pairing is missing, open
   `InstanceListView` with a recovery/empty state instead of
   `HouseholdHomeView`.
3. Keep iPhone and machine approval UI as overlays on `InstanceListView`.
4. Preserve a recovery action for scanning or finding the Mac again.
5. Avoid showing raw household ids in the default user-facing screen.

## Open Questions

- Should `HouseholdHomeView` be deleted entirely, or kept as a debug/internal
  view?
- What should the empty state say when the household exists but no Mac can be
  reached?
- Should Settings expose household identity details instead of the main screen?
- Which automated UI test should own the "household exists, no local Mac"
  recovery path?
