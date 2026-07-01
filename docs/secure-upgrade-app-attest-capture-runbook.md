# Secure/Upgrade App Attest Positive Capture Runbook

Status: planned capture-only runbook for the Secure/Upgrade 3b positive
hardware gate. This is not a product proof path, not strong-owner minting, not a
fan-out gate, and not `reviewed-core-v2` activation.

The backend App Attest verifier is implemented and negative-tested, and the
Apple App Attestation Root CA provenance is cross-checked against Apple public
PKI. The remaining 3b seal gate is one positive attestation object captured from
a real iPhone build signed for the app identity in the Secure/Upgrade
transcript.

## Safety Rules

- Use a disposable iOS `Dev` build only. Do not add this capture path to the
  shipping product flow.
- Do not modify, quit, restart, or overwrite the user's installed macOS
  `/Applications/Soyeht.app`.
- Keep the existing Swift STOP guard in force until the capture harness is
  reviewed. Product sources currently forbid App Attest runtime wiring.
- Do not commit, paste, log, or attach raw attestation objects, certificate
  blobs, credential ids, device names, account names, local hostnames, IPs, or
  other personal infrastructure values.
- Write raw capture output only to an ignored local path outside the repository.

## Required Build Shape

Use the iOS app's `Dev` configuration:

- bundle id: `com.soyeht.app.dev`
- entitlement file: `TerminalApp/Soyeht/SoyehtDev.entitlements`
- App Attest entitlement value: `development`
- Xcode capability: App Attest / DeviceCheck for the same bundle id
- device: a physical iPhone where App Attest is supported

The production build requires the production entitlement and the production
bundle id. Do not mix development App Attest evidence with a production
transcript.

## Capture Contract

The harness must obtain a server-issued or fixture transcript with:

- `challenge_id` set to `su-capture-<capture_run_id>` for the current script
  run;
- `app_team_id` matching the signed build's Team ID;
- `app_bundle_id` matching the signed build's bundle id;
- `proof_environment` matching the entitlement environment;
- `proof_key_id` equal to the App Attest key id returned by the platform;
- `challenge_sha256_hex` derived from the canonical transcript bytes as
  `SHA256("soyeht-secure-upgrade-v1\0" || canonical_transcript_cbor)`.

The iPhone capture harness then:

1. Checks `DCAppAttestService.shared.isSupported`.
2. Calls `generateKey()`.
3. Builds a canonical Secure/Upgrade transcript whose `proof_key_id` is the key
   id returned by the platform.
4. Computes the domain-separated `challenge_digest` from the stored canonical
   transcript bytes.
5. Calls `attestKey(keyId, clientDataHash: challenge_digest)`.
6. Writes the local-only fixture JSON below and a sanitized capture result with
   the same `capture_run_id`.

The checked-in harness is the manual XCTest
`SecureUpgradeAppAttestCaptureTests/testCaptureRealIphoneAppAttestPositiveFixture`
under `TerminalApp/SoyehtTests`. It is not part of product runtime and only runs
when `SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1` is present.
At startup it clears its capture output directory so a skipped run cannot reuse
an older fixture.

## Local Fixture Schema

The Rust verifier test consumes this JSON through
`SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE`:

```json
{
  "contract": "secure_upgrade_app_attest_positive_fixture_v1",
  "capture_run_id": "<script-generated run id>",
  "environment": "development",
  "canonical_transcript_cbor_hex": "<hex>",
  "challenge_sha256_hex": "<hex>",
  "app_attest_key_id": "<platform key id>",
  "attestation_object_cbor_base64": "<standard base64>",
  "verification_time_unix": 1714972800
}
```

The fixture is raw security evidence. Keep it local and untracked. Sanitized
reports may include only the contract name, environment, verifier pass/fail,
root fingerprint, the current capture run id, and the fact that the challenge
digest matched the transcript.

## Backend Verification

Choose local-only output and work directories outside the repository. The
fixture parent and work directory must be user-owned private directories; the
script refuses repo paths and shared parents such as a fixture directly under
`/tmp`.

```sh
export SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE="$HOME/Library/Application Support/SoyehtDev/SecureUpgradeAppAttest/positive-fixture.json"
export SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR="$HOME/Library/Application Support/SoyehtDev/SecureUpgradeAppAttest/work"
```

Provide the device selection through environment variables. The script requires
explicit selection and refuses to infer a device, because a dev machine may have
multiple physical iOS devices visible. Keep their values local; do not paste
them into reports:

```sh
export SOYEHT_IOS_DEVICE_DESTINATION='platform=iOS,id=<device-id>'
export SOYEHT_IOS_DEVICE_ID='<device-id>'
export SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID='<team-id>'
export THEYOS_DIR="/path/to/theyos"
```

Optional signing preflight, before choosing a device or fixture path:

```sh
SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
SOYEHT_SECURE_UPGRADE_APP_ATTEST_PREFLIGHT_ONLY=1 \
  scripts/secure-upgrade-app-attest-capture.sh
```

The preflight runs a generic iOS `build-for-testing` for the `Soyeht Dev`
scheme and emits the same sanitized JSON result shape as the capture path. If
the Dev provisioning profile does not include App Attest, the capture script
returns `app_attest_capability_missing_from_dev_profile`. Enable App Attest /
DeviceCheck for the Dev App ID, refresh the profile, and rerun. Do not work
around this by using a production bundle or by committing capture output.

To validate the harness contract without an iPhone, fixture, or Apple profile
change, run the local self-test:

```sh
scripts/test-secure-upgrade-app-attest-capture.sh
```

It checks the skipped/refused paths and the sanitized preflight classifier with
a stubbed `xcodebuild`. It does not capture or install any fixture.

Run the capture from the `soyeht-ios` repository root:

```sh
SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
  scripts/secure-upgrade-app-attest-capture.sh
```

The script builds and runs only the manual capture test in the `Soyeht Dev`
scheme, downloads `capture-result.json` and `positive-fixture.json` from the Dev
app data container, validates that the result is `passed` for the current
`capture_run_id`, validates that the fixture carries the same run id, installs
the fixture into `SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE`, and, when
`THEYOS_DIR` is set, runs the Rust ignored verifier test:

```sh
cargo test -j 1 -p household-rs --test secure_upgrade_app_attest_bindings \
  real_iphone_app_attest_fixture_verifies_current_apple_chain \
  -- --ignored --nocapture
```

A green Rust run proves the captured attestation object verifies against the
pinned Apple App Attestation root, the transcript-derived `challenge_digest`,
the app identifier hash, the proof environment AAGUID, the attestation counter,
the App Attest key binding expected by the backend verifier, and the current
`capture_run_id` parsed from the canonical transcript challenge id. A
capture-only script result does not seal Gate 2; closeout requires
`rust_verifier` to be `passed`.

This still does not mint strong owner provenance by itself. Minting remains
gated on the later ceremony slice, source guards, and reviewer approval.
