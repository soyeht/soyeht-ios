## iOS architecture rules

- iOS UI must consume `SoyehtIdentity.shared`. `HouseholdSessionStore`
  and `ActiveHouseholdState` are protocol/storage layer — only
  `TerminalApp/Soyeht/Household/*` orchestrators reference them
  directly. See `docs/identity-facade.md`.
- iOS Claw Store flows speak `ClawInstallTarget` (= `Server.ID`). New
  iOS code must not introduce new uses of `ClawAPITarget.household`.
  The currently allowed sites are:
    - `ClawStore/ClawInstallTargetResolver.swift` — the temporary
      single-Mac household fallback resolver.
    - `ClawStore/ClawStoreView.swift` and
      `ClawStore/ClawDetailView.swift` — two legacy `?? .household`
      ViewModel fallbacks created by PR-3 for the `.unavailable`
      resolution path. Both are documented and locked in place by
      `SoyehtTests/LegacyBoundaryUsageTests`
      (`test_clawAPITargetHouseholdFallback_onlyInDocumentedSites` plus
      a per-file exactly-1 count). They are follow-up for removal once
      the ViewModels accept an optional target — see the TODO in
      `docs/architecture.md`.
  The `.householdStore` / `.householdDetail` route cases stay alive in
  `ClawRoute` for macOS but iOS must never construct them. See
  `docs/claw-install-target.md` and `docs/architecture.md`. Note: PR-3
  corrected target/routing only — install on a Mac may still fail with
  `base image not ready` until the guest-image preparation PR lands.

## theyos-engine version pin

Soyeht.app bundles a Rust binary from a separate repo (`soyeht/theyos`).
The version is pinned in `scripts/theyos-engine.version`. **Before bumping
it, read `docs/engine-version.md`** — it explains when bumping is the right
fix (vs masking a real bug) and the exact steps to bump safely.

Symptom that usually means the engine is outdated: iPhone shows "Couldn't
add this Mac — Soyeht returned an unexpected response type" or hits a 404
on a `/bootstrap/*` route.

## macOS Release Signing

- Release workflow: `.github/workflows/macos-release.yml`.
- DMG/notarization helper: `scripts/build-dmg.sh`.
- Release docs and secret inventory: `docs/macos-updates.md`.
- Local Developer ID certificate export: `~/Documents/theyos-developer-id.p12`.
- Local APNs key for the macOS engine: `~/.soyeht/apns.p8`.
- Local App Store Connect notary API key: `~/.soyeht/notary/AuthKey_6MFCQ8AWV5.p8`.
- Local notarytool profile: `soyeht-notary`.
- Team ID: `W7677A5BK2`.
- Signing identity: `Developer ID Application: Gilberto Filho (W7677A5BK2)`.

Do not print, commit, or paste secret values. The required GitHub Actions
secrets live on `soyeht/soyeht-ios`. CI notarization uses the
`APPLE_NOTARY_*` App Store Connect Team API key secrets, not
`APPLE_ID_APP_PASSWORD`.

GitHub secrets are write-only: agents can verify that a secret exists, but
cannot read it back. If the notary API key is lost or compromised, revoke it in
App Store Connect and replace both the GitHub secrets and the local `.p8` file.
The local fallback is to build with `scripts/build-dmg.sh` and
`NOTARIZATION_PROFILE=soyeht-notary`, then upload `Soyeht.dmg` and
`appcast.xml` to the GitHub Release.

Release checklist for agents:

1. Verify required secrets exist with `gh secret list --repo soyeht/soyeht-ios`.
   Required release secrets are `SPARKLE_PRIVATE_KEY`,
   `SOYEHT_SPARKLE_PUBLIC_ED_KEY`, `APPLE_DEVELOPER_ID_P12_BASE64`,
   `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_NOTARY_KEY_P8_BASE64`,
   `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_TEAM_ID`,
   `APPLE_CODESIGN_IDENTITY`, and `SOYEHT_APNS_P8_BASE64`.
2. Do not use or recreate `APPLE_ID_APP_PASSWORD`; CI notarization should use
   the App Store Connect API key path only.
3. Release by pushing a tag like `mac-v0.1.11`; the `macOS Release` workflow
   must build, sign, notarize, staple, generate `appcast.xml`, and publish the
   release assets.
4. After release, validate the public download, not just local artifacts:
   `curl -fsSL https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg`,
   then run `xcrun stapler validate` and
   `spctl --assess --verbose=4 --type open --context context:primary-signature`.
5. If CI notarization fails, inspect the workflow log first. Only use the
   local `soyeht-notary` fallback to publish when CI is blocked and document
   that explicitly in the final status.

## Local Soyeht App Safety

- Never quit, kill, restart, uninstall, overwrite, or otherwise disrupt the
  user's installed `/Applications/Soyeht.app` process. The user runs real work
  there. If a task appears to require restarting the shipping app, ask the user
  to do it manually and wait for confirmation.
- `Soyeht Dev.app` is the disposable test target. Agents may quit, reinstall,
  delete, or relaunch the Dev app when validation requires it, as long as the
  original Soyeht app is left untouched.

## iOS / Mac Onboarding Rules

- Add Mac has two valid paths after an owner iPhone already has an active
  Soyeht: iPhone-minted setup invitation, and Mac-shown pair-machine QR. The
  Mac QR path is gated by `/bootstrap/status.engine_version >= 0.1.19` and must
  not call `/bootstrap/pair-machine/local/stage` until the user explicitly
  chooses to join an existing Soyeht.
