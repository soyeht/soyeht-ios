<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/017-onboarding-canonical/plan.md`
<!-- SPECKIT END -->

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
