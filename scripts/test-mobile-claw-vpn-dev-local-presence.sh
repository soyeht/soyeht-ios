#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_file="${script_dir}/mobile-claw-vpn-dev-local-presence.swift"
self_test_source="${script_dir}/test-mobile-claw-vpn-dev-local-presence.swift"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-local-presence-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT
chmod 700 "${tmp_root}"

production_bin="${tmp_root}/local-presence"
self_test_bin="${tmp_root}/local-presence-self-test"

/usr/bin/xcrun swiftc -parse-as-library -typecheck "${source_file}"
/usr/bin/xcrun swiftc -parse-as-library "${source_file}" -o "${production_bin}"
/usr/bin/xcrun swiftc -parse-as-library \
  -D MOBILE_CLAW_VPN_LOCAL_PRESENCE_SELF_TEST \
  "${source_file}" "${self_test_source}" -o "${self_test_bin}"
chmod 700 "${production_bin}" "${self_test_bin}"
printf 'ok syntax_and_build\n'

self_test_output="$(${self_test_bin})"
if [[ "${self_test_output}" != "local presence self-test passed" ]]; then
  printf 'unexpected self-test output\n' >&2
  exit 1
fi
printf 'ok software_codec_and_binding_matrix\n'

assert_refused() {
  local name="$1"
  local expected_reason="$2"
  shift 2

  local output status
  set +e
  output="$("$@")"
  status=$?
  set -e
  if [[ "${status}" != "1" ]]; then
    printf '%s: expected exit 1, got %s\n' "${name}" "${status}" >&2
    exit 1
  fi
  python3 - "${output}" "${expected_reason}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected_reason = sys.argv[2]
assert set(payload) == {
    "status", "reason", "challenge_sha256", "execution_run_id",
    "local_biometric_presence_observed", "owner_authenticated",
    "execution_authorized", "app_launch_attempted", "raw_values_printed",
}, payload
assert payload["status"] == "refused", payload
assert payload["reason"] == expected_reason, payload
assert payload["challenge_sha256"] is None, payload
assert payload["execution_run_id"] is None, payload
assert payload["local_biometric_presence_observed"] is False, payload
assert payload["owner_authenticated"] is False, payload
assert payload["execution_authorized"] is False, payload
assert payload["app_launch_attempted"] is False, payload
assert payload["raw_values_printed"] is False, payload
for needle in (
    "private-device-id-needle", "private-claw-id-needle",
    "private-host-needle", "private-token-needle",
):
    assert needle not in sys.argv[1], (needle, payload)
PY
  printf 'ok %s\n' "${name}"
}

assert_refused "empty_stdin_is_refused" "local_presence_input_refused" \
  env \
    SOYEHT_PRIVATE_DEVICE=private-device-id-needle \
    SOYEHT_PRIVATE_CLAW=private-claw-id-needle \
    SOYEHT_PRIVATE_HOST=private-host-needle \
    SOYEHT_PRIVATE_TOKEN=private-token-needle \
    "${production_bin}"

assert_refused "arguments_are_refused_before_presence" \
  "local_presence_argument_refused" \
  "${production_bin}" unexpected

python3 - "${source_file}" "${self_test_source}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
self_test = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

assert "readBoundedStandardInput()" in source
assert "FileHandle.standardInput.read(" in source
assert "SecureEnclave.P256.Signing.PrivateKey" in source
assert "[.privateKeyUsage, .biometryCurrentSet]" in source
assert "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in source
assert "touchIDAuthenticationAllowableReuseDuration = 0" in source
assert "defer { context.invalidate() }" in source
assert "try challenge.validate(now: clock())" in source
assert source.count("try challenge.validate(now: clock())") == 2
assert 'status: "local_biometric_presence_observed"' in source
assert "localBiometricPresenceObserved: true" in source
assert "ownerAuthenticated: false" in source
assert "executionAuthorized: false" in source
assert "appLaunchAttempted: false" in source
assert "maximumChallengeTTL: Int64 = 120" in source
assert "canonical == input" in source
assert "P256.Signing.PrivateKey()" not in source
assert "P256.Signing.PrivateKey()" in self_test

for forbidden in (
    "dataRepresentation", "key_reference", "anchor", "proof_written",
    "owner_proof", "evaluatePolicy", ".deviceUnlocked", "softwareKeychain",
    "FileManager.default", "CommandLine.arguments[1]",
):
    assert forbidden not in source, forbidden

for field in (
    "attemptID", "readinessRunID", "artifactSHA", "executionManifestSHA256",
    "deviceBinding", "executionRunID", "replayNonce", "createdAtUnix",
    "expiresAtUnix", "bundleID", "deviceAlias", "clawAlias",
    "ownerPresentRequired", "rawValuesPrinted",
):
    assert f"fixture({field}:" in self_test, field

print("ok source_boundary_guards")
PY

printf 'mobile Claw VPN DEV local presence tests passed\n'
