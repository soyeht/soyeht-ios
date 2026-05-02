# macOS Updates

Soyeht for macOS uses Sparkle and a free GitHub-hosted release flow:

- initial download: `https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg`
- update feed: `https://github.com/soyeht/soyeht-ios/releases/latest/download/appcast.xml`
- update archive: `Soyeht.dmg` on each GitHub Release
- release trigger: push a tag named `mac-vX.Y.Z`

## One-Time Setup

1. Generate a Sparkle key pair locally:

   ```sh
   xcodebuild -resolvePackageDependencies -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac
   SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d | tail -n 1)
   "$SPARKLE_BIN/generate_keys" --account soyeht-mac
   "$SPARKLE_BIN/generate_keys" --account soyeht-mac -x /tmp/soyeht-sparkle-private-key
   ```

2. Add repository secrets:

   ```sh
   gh secret set SPARKLE_PRIVATE_KEY < /tmp/soyeht-sparkle-private-key
   gh secret set SOYEHT_SPARKLE_PUBLIC_ED_KEY --body "PUBLIC_KEY_PRINTED_BY_generate_keys"
   rm /tmp/soyeht-sparkle-private-key
   ```

The private key must never be committed. The public key is injected into the app at build time.

## Releasing

Create and push a macOS release tag:

```sh
git tag -a mac-v1.0.1 -m "Soyeht 1.0.1"
git push origin mac-v1.0.1
```

The `macOS Release` workflow builds the app, creates `Soyeht.dmg`, signs that DMG for Sparkle, generates `appcast.xml`, and uploads both files to the GitHub Release.

The DMG contains `Soyeht.app` and an `Applications` symlink. Users should drag the app to Applications before launching it; running directly from the mounted DMG can prevent Sparkle from replacing the app later because the mounted image is read-only.

## Free Option Limitation

This flow is free and works for open-source distribution, but it does not notarize the app. For a fully trusted first-install experience without Gatekeeper warnings, a paid Apple Developer ID certificate and notarization step are still required.
