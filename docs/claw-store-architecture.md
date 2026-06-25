# Claw Store Architecture Pointer

The canonical Claw Store architecture map lives in the `theyos` repo:

```text
theyos/docs/claw-store-architecture.md
```

This Swift-side file is only a discoverability pointer. Do not duplicate route
tables, auth matrices, or backend lifecycle rules here.

Open these Swift files when changing the client side of Claw Store:

- `Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json`
  is the vendored byte-for-byte copy of the Rust contract.
- `scripts/check-cross-repo-fixtures.sh` verifies the vendored contract and
  household docs mirror against `theyos`.
- `scripts/sync-cross-repo-fixtures.sh` syncs Claw Store fixtures from
  `theyos`; do not hand-edit the vendored JSON.
- `Packages/SoyehtCore/Sources/SoyehtCore/API/ServerKind+Endpoint.swift` owns
  kind-aware endpoint paths.
- `Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient+Claws.swift` owns
  Claw Store request bindings.
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawInventoryService.swift`
  owns catalog and instance inventory fetch/poll behavior.
- `Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawStoreViewModel.swift`
  owns shared Claw Store view-model state and machine target identity.
- `TerminalApp/Soyeht/ClawStore/ClawInstallTargetResolver.swift` is the iOS
  bridge from UI install target to wire target.
- `TerminalApp/SoyehtTests/ClawRouteUsageTests.swift` and
  `TerminalApp/SoyehtTests/LegacyBoundaryUsageTests.swift` guard route and
  legacy-boundary usage.

Useful local checks:

```sh
THEYOS_DIR=<path-to-theyos> scripts/check-cross-repo-fixtures.sh
swift test --package-path Packages/SoyehtCore --filter 'ClawStoreContractFixtureTests|SoyehtAPIClientKindTests|HouseholdAPIClientTests|ClawInventoryServiceTests|ClawStoreViewModelTargetTests|ClawStoreViewModelServiceAdoptionTests|GuestImageReadinessTests|GuestImagePrepareClientTests'
git diff --check
git diff -U0 -- docs/claw-store-architecture.md | rg -nP '^\+.*[^\x00-\x7F]' || true
```
