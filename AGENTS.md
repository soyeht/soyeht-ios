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
