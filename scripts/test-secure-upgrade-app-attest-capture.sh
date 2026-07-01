#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
capture_script="${script_dir}/secure-upgrade-app-attest-capture.sh"

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

assert_json() {
  local output="$1"
  local expected_status="$2"
  local expected_reason="$3"
  local expected_fixture_written="$4"
  local expected_rust_verifier="$5"

  python3 - "${output}" "${expected_status}" "${expected_reason}" \
    "${expected_fixture_written}" "${expected_rust_verifier}" <<'PY'
import json
import sys

raw, expected_status, expected_reason, expected_fixture_written, expected_rust_verifier = sys.argv[1:]
payload = json.loads(raw)
assert payload["status"] == expected_status, payload
if expected_reason == "null":
    assert payload["reason"] is None, payload
else:
    assert payload["reason"] == expected_reason, payload
assert str(payload["fixture_written"]).lower() == expected_fixture_written, payload
assert payload["rust_verifier"] == expected_rust_verifier, payload
PY
}

assert_case() {
  local name="$1"
  local expected_exit="$2"
  local expected_status="$3"
  local expected_reason="$4"
  local expected_fixture_written="$5"
  local expected_rust_verifier="$6"
  shift 6

  local output status
  set +e
  output="$("$@")"
  status=$?
  set -e
  if [[ "${status}" != "${expected_exit}" ]]; then
    printf 'case %s: expected exit %s, got %s\noutput: %s\n' \
      "${name}" "${expected_exit}" "${status}" "${output}" >&2
    exit 1
  fi
  assert_json "${output}" "${expected_status}" "${expected_reason}" \
    "${expected_fixture_written}" "${expected_rust_verifier}"
  printf 'ok %s\n' "${name}"
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-app-attest-capture-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT

assert_case "skips_without_opt_in" 0 "skipped" \
  "SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE_not_set" "false" "not_run" \
  "${capture_script}"

assert_case "skips_without_explicit_device_destination" 0 "skipped" \
  "ios_device_destination_missing_explicit_selection_required" "false" "not_run" \
  env SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    "${capture_script}"

assert_case "skips_without_explicit_device_id" 0 "skipped" \
  "ios_device_id_missing_explicit_selection_required" "false" "not_run" \
  env SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    SOYEHT_IOS_DEVICE_DESTINATION='id=example' \
    "${capture_script}"

assert_case "refuses_fixture_parent_not_owned" 0 "refused" \
  "fixture_parent_not_owned" "false" "not_run" \
  env SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE=/tmp/soyeht-secure-upgrade-fixture.json \
    SOYEHT_IOS_DEVICE_DESTINATION='id=example' \
    SOYEHT_IOS_DEVICE_ID=example \
    "${capture_script}"

fixture_dir="${tmp_root}/fixture"
mkdir -p "${fixture_dir}"
assert_case "refuses_work_dir_inside_repo" 0 "refused" \
  "work_dir_inside_repo_refused" "false" "not_run" \
  env SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE="${fixture_dir}/positive-fixture.json" \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR="${repo_root}/capture-work" \
    SOYEHT_IOS_DEVICE_DESTINATION='id=example' \
    SOYEHT_IOS_DEVICE_ID=example \
    "${capture_script}"

fake_bin="${tmp_root}/bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/xcodebuild" <<'SH'
#!/usr/bin/env bash
echo "error: Provisioning profile doesn't include com.apple.developer.devicecheck.appattest-environment entitlement."
exit 65
SH
chmod +x "${fake_bin}/xcodebuild"

assert_case "preflight_classifies_missing_app_attest_entitlement" 65 "failed" \
  "app_attest_capability_missing_from_dev_profile" "false" "not_run" \
  env PATH="${fake_bin}:${PATH}" \
    SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_PREFLIGHT_ONLY=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR="${tmp_root}/preflight-work" \
    "${capture_script}"

cat >"${fake_bin}/xcodebuild" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${fake_bin}/xcodebuild"

assert_case "preflight_passes_without_device_or_fixture" 0 "preflight_passed" \
  "null" "false" "not_run" \
  env PATH="${fake_bin}:${PATH}" \
    SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_PREFLIGHT_ONLY=1 \
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR="${tmp_root}/preflight-pass-work" \
    "${capture_script}"
