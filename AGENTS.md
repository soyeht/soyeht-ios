## macOS Release Signing

- Release workflow: `.github/workflows/macos-release.yml`.
- DMG/notarization helper: `scripts/build-dmg.sh`.
- Release docs and secret inventory: `docs/macos-updates.md`.
- Local Developer ID certificate export: `~/Documents/theyos-developer-id.p12`.
- Local APNs key for the macOS engine: `~/.soyeht/apns.p8`.
- Local notarytool profile: `soyeht-notary`.
- Team ID: `W7677A5BK2`.
- Signing identity: `Developer ID Application: Gilberto Filho (W7677A5BK2)`.

Do not print, commit, or paste secret values. The required GitHub Actions
secrets live on `soyeht/soyeht-ios` and use the same Apple secret names as the
`soyeht/theyos` release workflow.

GitHub secrets are write-only: agents can verify that a secret exists, but
cannot read it back. If CI notarization fails with `401 Invalid credentials`,
rotate `APPLE_ID_APP_PASSWORD` with a new Apple app-specific password. The
local fallback is to build with `scripts/build-dmg.sh` and
`NOTARIZATION_PROFILE=soyeht-notary`, then upload `Soyeht.dmg` and
`appcast.xml` to the GitHub Release.
