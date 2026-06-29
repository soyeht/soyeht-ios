# macOS Local Apple Attestation Capture Runbook

Status: operator runbook for the A3 evidence gate. This is not active local
enrollment and not flip approval.

This runbook produces the untracked fixture consumed by the theyOS #204 manual
hardware harness. It uses `Soyeht Dev.app` only. Never run this against the
installed shipping `/Applications/Soyeht.app`.

Prerequisite: the Dev engine must include the theyOS #206 local peer-auth
selector, so the `SoyehtDev` engine namespace verifies `com.soyeht.mac.dev`
instead of the production bundle id.

## What This Proves

A green run of this capture plus the theyOS #204 harness proves:

- the Dev app can request a live server-issued `/registration/local/start`;
- the client can ask the platform for the API-applicable Direct attestation and
  user-verification options;
- the resulting fresh hardware attestation can pass the pinned Apple-chain
  verifier plus the five local checks in the #204 harness;
- the capture and verifier agree internally on the captured challenge.

It does **not** prove server-issued challenge binding, single-use, anti-replay,
or active local enrollment. Those remain A3 active-commit properties.

## Safety Rules

- Use only a freshly built `Soyeht Dev.app`.
- The Dev app must be signed with the Soyeht Team ID. Do not disable code
  signing for the capture build.
- Do not quit, overwrite, restart, or otherwise touch `/Applications/Soyeht.app`.
- Write the raw fixture only to an explicit untracked local path.
- If you request a sanitized capture-result file, use a different path from the
  raw fixture. The helper refuses same-path output.
- Do not commit, paste, attach, or log the raw fixture, `attestationObject`,
  `clientDataJSON`, credential IDs, certificates, device names, account names,
  socket paths, or local infrastructure values.
- The captured passkey is throwaway/orphan evidence. Delete it after the dump.
- The real owner credential must be enrolled fresh in the later A3 active-commit
  slice.

## 1. Choose Local-Only Output Paths

Pick a local directory outside the repository. Keep it private to the user:

```sh
export SOYEHT_ATTESTATION_EVIDENCE_DIR="$HOME/Library/Application Support/SoyehtDev/LocalAttestationEvidence"
mkdir -p "$SOYEHT_ATTESTATION_EVIDENCE_DIR"
chmod 700 "$SOYEHT_ATTESTATION_EVIDENCE_DIR"

export SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE="$SOYEHT_ATTESTATION_EVIDENCE_DIR/local-apple-attestation.json"
export SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE_RESULT="$SOYEHT_ATTESTATION_EVIDENCE_DIR/capture-result.json"
```

The raw fixture and sanitized result path must be different files. The helper
also refuses paths inside this repository.

## 2. Build a Disposable Dev App

From the `soyeht-ios` repository root:

```sh
export SOYEHT_CAPTURE_DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-local-attestation-capture.XXXXXX")"

xcodebuild build \
  -project TerminalApp/SoyehtMac.xcodeproj \
  -scheme SoyehtMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=W7677A5BK2 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' \
  -skipPackagePluginValidation \
  -derivedDataPath "$SOYEHT_CAPTURE_DERIVED_DATA"

export SOYEHT_DEV_APP_BUNDLE="$SOYEHT_CAPTURE_DERIVED_DATA/Build/Products/Debug/Soyeht Dev.app"
```

Do not point `SOYEHT_DEV_APP_BUNDLE` at `/Applications/Soyeht.app`. The helper
checks the bundle identifier, designated requirement, and Team ID, and refuses
non-dev or unsigned/ad-hoc bundles. The `CODE_SIGN_IDENTITY` override keeps the
Debug capture build on an Apple Development identity even if local release
settings specify a Developer ID identity.

## 3. Run the Dev Capture

```sh
SOYEHT_RUN_LOCAL_APPLE_ATTESTATION_CAPTURE=1 \
  scripts/dev-local-apple-attestation-capture.sh
```

Expected success includes these sanitized fields:

```json
{
  "status": "passed",
  "reason": null,
  "fixtureWritten": true
}
```

The printed JSON is sanitized. It is not the evidence. The evidence is the raw
fixture at `SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE`, and that file must stay
local and untracked.

If the helper reports `result_path_matches_fixture_path`,
`fixture_path_inside_repo_refused`, `result_path_inside_repo_refused`, or a
non-dev bundle/profile refusal, stop and fix the setup. Do not switch to the
shipping app.

If it reports `codesign_requirement_unavailable`, `codesign_identifier_not_dev`,
or `codesign_team_not_soyeht`, the Dev app was not signed in a way the engine
peer-auth verifier can accept. Rebuild the Dev app with normal signing; do not
bypass this guard.

## 4. Verify with the theyOS #204 Harness

From a theyOS checkout that includes the #204 harness:

```sh
export THEYOS_DIR="/path/to/theyos"
cd "$THEYOS_DIR"

SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE="$SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE" \
  cargo test -p household-rs --manifest-path admin/rust/Cargo.toml \
    macos_local_attested_registration_manual_hardware_fixture_verifies_current_apple_chain \
    -- --ignored --nocapture
```

Only report the sanitized verdict fields emitted by the harness:

- attestation format;
- UV;
- BE;
- BS;
- root policy version;
- root fingerprint;
- pass/fail status.

Do not report the raw fixture, credential IDs, certificate blobs, challenge,
origin, local socket path, or device/account names.

## 5. Cleanup

After the fixture has been captured and the harness verdict recorded:

1. Delete the throwaway passkey created by the capture from macOS Passwords /
   Passkeys.
2. Keep the raw fixture local until the A3 evidence review is complete.
3. Delete the raw fixture after it is no longer needed for the reviewed smoke.

Do not reuse the throwaway passkey as the real owner credential. A3 active
commit must perform a fresh enrollment ceremony.

## Failure Handling

- Capture failure: do not proceed to A3. Fix the Dev app/start endpoint setup and
  rerun the capture.
- Harness failure: treat the positive Apple-chain evidence as missing. Do not
  open an active-commit PR based on a failed or missing verdict.
- Any accidental raw-material disclosure: stop, revoke/clean up the throwaway
  credential, remove the leaked material, and re-run with a fresh capture.
