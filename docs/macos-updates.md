# macOS Updates

Soyeht for macOS uses Sparkle, Developer ID signing, Apple notarization,
and a GitHub-hosted release flow:

- initial download: `https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg`
- update feed: `https://github.com/soyeht/soyeht-ios/releases/latest/download/appcast.xml`
- update archive: `Soyeht.dmg` on each GitHub Release
- release trigger: push a tag named `mac-vX.Y.Z`
- signing identity: `Developer ID Application: Gilberto Filho (W7677A5BK2)`

## One-Time Setup

### Sparkle

Generate a Sparkle key pair locally:

```sh
xcodebuild -resolvePackageDependencies -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d | tail -n 1)
"$SPARKLE_BIN/generate_keys" --account soyeht-mac
"$SPARKLE_BIN/generate_keys" --account soyeht-mac -x /tmp/soyeht-sparkle-private-key
```

Add repository secrets:

```sh
gh secret set SPARKLE_PRIVATE_KEY --repo soyeht/soyeht-ios < /tmp/soyeht-sparkle-private-key
gh secret set SOYEHT_SPARKLE_PUBLIC_ED_KEY --repo soyeht/soyeht-ios --body "PUBLIC_KEY_PRINTED_BY_generate_keys"
rm /tmp/soyeht-sparkle-private-key
```

The private key must never be committed. The public key is injected into the app at build time.

### Developer ID and notarization

The release workflow imports a Developer ID `.p12` into a temporary keychain,
archives the app, exports it for Developer ID distribution, signs the DMG,
submits the DMG to Apple's notarization service, staples the ticket, then
generates `appcast.xml`.

Required GitHub Actions secrets:

| Secret | Value |
|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of the exported Developer ID `.p12`. Local source on the Mac: `~/Documents/theyos-developer-id.p12`. |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the App Store Connect Team API private key. Local source on the Mac: `~/.soyeht/notary/AuthKey_6MFCQ8AWV5.p8`. |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID. |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect Team API issuer ID. |
| `APPLE_TEAM_ID` | `W7677A5BK2`. |
| `APPLE_CODESIGN_IDENTITY` | `Developer ID Application: Gilberto Filho (W7677A5BK2)`. |

Optional, but recommended for push-assisted pairing:

| Secret | Value |
|---|---|
| `SOYEHT_APNS_P8_BASE64` | Base64 of the APNs key. Local source on the Mac: `~/.soyeht/apns.p8`. |

The `theyos` repo already uses the same Apple secret names. GitHub does not
let Actions read secrets across repositories, so they also need to exist on
`soyeht/soyeht-ios`.

GitHub secrets are write-only. If a future agent can see a secret in
`gh secret list`, that only means the secret exists; the value cannot be read
back. CI notarization uses the App Store Connect Team API key, not an Apple ID
app-specific password. If the private key is lost or compromised, revoke it in
App Store Connect, generate a new Team API key, update the three
`APPLE_NOTARY_*` secrets, and replace the local `.p8` file.

Useful local checks:

```sh
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile soyeht-notary
xcrun notarytool history \
  --key ~/.soyeht/notary/AuthKey_6MFCQ8AWV5.p8 \
  --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID"
```

## Releasing

Create and push a macOS release tag:

```sh
git tag -a mac-v1.0.1 -m "Soyeht 1.0.1"
git push origin mac-v1.0.1
```

The `macOS Release` workflow archives the app, signs it with Developer ID,
creates and signs `Soyeht.dmg`, notarizes and staples the DMG, signs it for
Sparkle, generates `appcast.xml`, and uploads both files to the GitHub Release.

The Mac local fallback is the `soyeht-notary` Keychain profile: build
the archive locally, run `scripts/build-dmg.sh` with
`NOTARIZATION_PROFILE=soyeht-notary`, generate `appcast.xml`, then upload
`Soyeht.dmg` and `appcast.xml` to the release. This uses the same Apple
notarization service, but reads the credential from the local Keychain profile.

The DMG contains `Soyeht.app` and an `Applications` symlink. Users should drag the app to Applications before launching it; running directly from the mounted DMG can prevent Sparkle from replacing the app later because the mounted image is read-only.
