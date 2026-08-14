# macOS Updates

Soyeht for macOS uses Sparkle, Developer ID signing, Apple notarization,
and a GitHub-hosted release flow:

- initial download: `https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg`
- update feed: `https://github.com/soyeht/soyeht-ios/releases/latest/download/appcast.xml`
- update archive: `Soyeht.dmg` on each GitHub Release
- release trigger: create the governed annotated ref `refs/tags/mac-vX.Y.Z`
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

Publication uses a five-operation guarded adapter family; the asset operation
is invoked once for each of the two assets. It requires a fresh `theyos`
checkout whose `main` contains the reviewed `governed-release` adapter and an
iOS target commit whose workflow contains the matching consumer contract. A
missing or mismatched guard is a hard failure; there is no unguarded fallback.
The adapter pins the reviewed workflow bytes, so workflow changes land by
updating the adapter contract first and then re-anchoring this consumer.

Freeze the release inputs first. `TARGET_OID` is the full iOS commit to build;
it must already be merged into iOS `main`. `EXPECTED_MAIN` is the full iOS
`main` OID observed for the current phase. The adapter checks both against
GitHub immediately before and after every mutation.

```sh
VERSION=0.1.19
TAG_REF="refs/tags/mac-v${VERSION}"
TARGET_OID="FULL_40_HEX_IOS_COMMIT"
EXPECTED_MAIN="FULL_40_HEX_IOS_MAIN"
GUARD="/absolute/path/to/theyos/scripts/safe_external_write.py"

printf 'Soyeht %s\n' "$VERSION" | python3 "$GUARD" --stdin -- \
  governed-release tag-object-create \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  > tag-object-receipt.json

TAG_OBJECT_OID="$(jq -er '.tag_object_oid' tag-object-receipt.json)"
printf 'Soyeht %s\n' "$VERSION" | python3 "$GUARD" --stdin -- \
  governed-release tag-ref-create \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  --tag-object-oid "$TAG_OBJECT_OID"
```

The tag-ref phase triggers `macOS Release`. That workflow verifies the complete
ref, annotated-tag type, peeled OID, checked-out OID, and declared marketing
version. It archives the app, signs it with Developer ID, creates and signs
`Soyeht.dmg`, notarizes and staples the DMG, generates `appcast.xml`, and ends
by uploading an Actions artifact. It has read-only repository permission and
does not create or publish a GitHub Release.

Download that exact run's artifact. It contains `Soyeht.dmg`, `appcast.xml`,
release notes, and `release-artifact-manifest.json`. Verify that the manifest's
contract, full ref, full OID, two release-asset names, sizes, and SHA-256 values
match the files before continuing. Then create the draft from the exact notes,
upload one asset per invocation, and publish only after the remote readback is
an exact two-asset match:

```sh
RELEASE_TITLE="Soyeht macOS ${VERSION}"
NOTES_PATH="/absolute/path/to/release-notes.md"
DMG_PATH="/absolute/path/to/Soyeht.dmg"
APPCAST_PATH="/absolute/path/to/appcast.xml"
MANIFEST_PATH="/absolute/path/to/release-artifact-manifest.json"

python3 "$GUARD" --stdin -- \
  governed-release release-draft-create \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  --tag-object-oid "$TAG_OBJECT_OID" \
  --title "$RELEASE_TITLE" \
  < "$NOTES_PATH" > release-draft-receipt.json
RELEASE_ID="$(jq -er '.release_id' release-draft-receipt.json)"

DMG_SIZE="$(jq -er '.release_assets[] | select(.name == "Soyeht.dmg") | .size' "$MANIFEST_PATH")"
DMG_SHA="$(jq -er '.release_assets[] | select(.name == "Soyeht.dmg") | .sha256' "$MANIFEST_PATH")"
APPCAST_SIZE="$(jq -er '.release_assets[] | select(.name == "appcast.xml") | .size' "$MANIFEST_PATH")"
APPCAST_SHA="$(jq -er '.release_assets[] | select(.name == "appcast.xml") | .sha256' "$MANIFEST_PATH")"

printf '' | python3 "$GUARD" --stdin -- governed-release asset-upload \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  --tag-object-oid "$TAG_OBJECT_OID" \
  --release-id "$RELEASE_ID" --asset-name Soyeht.dmg \
  --asset-path "$DMG_PATH" --asset-size "$DMG_SIZE" --asset-sha256 "$DMG_SHA"

printf '' | python3 "$GUARD" --stdin -- governed-release asset-upload \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  --tag-object-oid "$TAG_OBJECT_OID" \
  --release-id "$RELEASE_ID" --asset-name appcast.xml \
  --asset-path "$APPCAST_PATH" --asset-size "$APPCAST_SIZE" \
  --asset-sha256 "$APPCAST_SHA"

printf '' | python3 "$GUARD" --stdin -- governed-release release-publish \
  --tag-ref "$TAG_REF" --version "$VERSION" \
  --target-oid "$TARGET_OID" --expected-main "$EXPECTED_MAIN" \
  --tag-object-oid "$TAG_OBJECT_OID" \
  --release-id "$RELEASE_ID" \
  --asset "Soyeht.dmg:${DMG_SIZE}:${DMG_SHA}" \
  --asset "appcast.xml:${APPCAST_SIZE}:${APPCAST_SHA}"
```

Each phase performs one mutation and then reads the created object back. Reuse,
target drift, a lightweight or mismatched tag, an existing asset name, an extra
asset, or a size/digest mismatch stops the sequence. Repository-level immutable
releases are a separate setting: this contract proves the immediate readback
and absence of versioned bypasses, not permanence against a later administrator.

The Mac local fallback is the `soyeht-notary` Keychain profile: build
the archive locally, run `scripts/build-dmg.sh` with
`NOTARIZATION_PROFILE=soyeht-notary`, and generate `appcast.xml`. This uses the
same Apple notarization service but reads the credential from the local
Keychain profile. Any resulting publication still uses the guarded draft,
single-asset, and publish phases above; local building does not bypass them.

The DMG contains `Soyeht.app` and an `Applications` symlink. Users should drag the app to Applications before launching it; running directly from the mounted DMG can prevent Sparkle from replacing the app later because the mounted image is read-only.
