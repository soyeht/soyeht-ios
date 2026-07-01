#!/usr/bin/env bash
set -euo pipefail

json() {
  printf '{"status":"%s","reason":%s,"fixture_written":%s,"rust_verifier":%s,"capture_run_id":%s}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

normalize_path() {
  python3 -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"
}

is_inside_repo() {
  local candidate="$1"
  case "${candidate}" in
    "${repo_root}"|"${repo_root}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_private_dir() {
  local dir="$1"
  local label="$2"

  if [[ -e "${dir}" && ! -d "${dir}" ]]; then
    json "refused" "$(json_string "${label}_not_directory")" "false" "$(json_string "not_run")" "null"
    exit 0
  fi
  mkdir -p "${dir}"
  if [[ ! -O "${dir}" ]]; then
    json "refused" "$(json_string "${label}_not_owned")" "false" "$(json_string "not_run")" "null"
    exit 0
  fi
  if ! chmod 700 "${dir}"; then
    json "refused" "$(json_string "${label}_chmod_failed")" "false" "$(json_string "not_run")" "null"
    exit 0
  fi
}

classify_xcode_failure() {
  local log_path="$1"

  python3 - "${log_path}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    log = f.read()

if re.search(
    r"doesn't include (?:the )?(?:App Attest capability|com\.apple\.developer\.devicecheck\.appattest-environment entitlement)",
    log,
    re.IGNORECASE,
):
    print("app_attest_capability_missing_from_dev_profile")
elif re.search(r"Missing test product", log, re.IGNORECASE):
    print("xctestrun_product_missing")
elif re.search(r"No profiles for|requires a provisioning profile|provisioning profile", log, re.IGNORECASE):
    print("provisioning_profile_unavailable")
elif re.search(r"Signing for .* requires a development team|requires a development team", log, re.IGNORECASE):
    print("development_team_unavailable")
elif re.search(r"Timed out|The request timed out|Unable to find a destination", log, re.IGNORECASE):
    print("ios_device_destination_unavailable")
else:
    print("xcodebuild_capture_test_failed")
PY
}

if [[ "${SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE:-}" != "1" ]]; then
  json "skipped" "$(json_string "SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE_not_set")" "false" "$(json_string "not_run")" "null"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
expected_bundle_id="${SOYEHT_EXPECTED_BUNDLE_ID:-com.soyeht.app.dev}"

if [[ "${SOYEHT_SECURE_UPGRADE_APP_ATTEST_PREFLIGHT_ONLY:-}" == "1" ]]; then
  work_dir="${SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/soyeht-app-attest-preflight.XXXXXX")}"
  work_dir="$(normalize_path "${work_dir}")"
  if is_inside_repo "${work_dir}"; then
    json "refused" "$(json_string "work_dir_inside_repo_refused")" "false" "$(json_string "not_run")" "null"
    exit 0
  fi
  prepare_private_dir "${work_dir}" "work_dir"

  xcode_log="${work_dir}/xcodebuild-preflight.log"
  set +e
  xcodebuild build-for-testing \
    -skipPackagePluginValidation \
    -project "${repo_root}/TerminalApp/Soyeht.xcodeproj" \
    -scheme "Soyeht Dev" \
    -configuration Dev \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${work_dir}/DerivedData" \
    DEVELOPMENT_TEAM="${SOYEHT_IOS_DEVELOPMENT_TEAM:-${SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID:-W7677A5BK2}}" \
    CODE_SIGN_STYLE=Automatic \
    >"${xcode_log}" 2>&1
  xcode_status=$?
  set -e

  if [[ "${xcode_status}" != "0" ]]; then
    json "failed" "$(json_string "$(classify_xcode_failure "${xcode_log}")")" "false" "$(json_string "not_run")" "null"
    exit "${xcode_status}"
  fi
  json "preflight_passed" "null" "false" "$(json_string "not_run")" "null"
  exit 0
fi

if [[ -z "${SOYEHT_IOS_DEVICE_DESTINATION:-}" ]]; then
  json "skipped" "$(json_string "ios_device_destination_missing_explicit_selection_required")" "false" "$(json_string "not_run")" "null"
  exit 0
fi

if [[ -z "${SOYEHT_IOS_DEVICE_ID:-}" ]]; then
  json "skipped" "$(json_string "ios_device_id_missing_explicit_selection_required")" "false" "$(json_string "not_run")" "null"
  exit 0
fi

if [[ -z "${SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE:-}" ]]; then
  json "refused" "$(json_string "fixture_path_missing")" "false" "$(json_string "not_run")" "null"
  exit 0
fi

fixture_path="$(normalize_path "${SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE}")"
if is_inside_repo "${fixture_path}"; then
  json "refused" "$(json_string "fixture_path_inside_repo_refused")" "false" "$(json_string "not_run")" "null"
  exit 0
fi

fixture_parent="$(dirname "${fixture_path}")"
prepare_private_dir "${fixture_parent}" "fixture_parent"

work_dir="${SOYEHT_SECURE_UPGRADE_APP_ATTEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/soyeht-app-attest-capture.XXXXXX")}"
work_dir="$(normalize_path "${work_dir}")"
if is_inside_repo "${work_dir}"; then
  json "refused" "$(json_string "work_dir_inside_repo_refused")" "false" "$(json_string "not_run")" "null"
  exit 0
fi
prepare_private_dir "${work_dir}" "work_dir"

derived_data="${work_dir}/DerivedData"
xcode_log="${work_dir}/xcodebuild.log"
copy_log="${work_dir}/devicectl-copy.log"
download_dir="${work_dir}/download"
mkdir -p "${download_dir}"

capture_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
result_bundle="${work_dir}/SecureUpgradeAppAttestCapture-${capture_run_id}.xcresult"

export SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE=1
export SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID="${SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID:-W7677A5BK2}"
export SOYEHT_SECURE_UPGRADE_APP_ATTEST_CAPTURE_RUN_ID="${capture_run_id}"
export SOYEHT_EXPECTED_BUNDLE_ID="${expected_bundle_id}"

set +e
xcodebuild build-for-testing \
  -skipPackagePluginValidation \
  -project "${repo_root}/TerminalApp/Soyeht.xcodeproj" \
  -scheme "Soyeht Dev" \
  -configuration Dev \
  -destination "${SOYEHT_IOS_DEVICE_DESTINATION}" \
  -only-testing:SoyehtTests/SecureUpgradeAppAttestCaptureTests/testCaptureRealIphoneAppAttestPositiveFixture \
  -derivedDataPath "${derived_data}" \
  DEVELOPMENT_TEAM="${SOYEHT_IOS_DEVELOPMENT_TEAM:-${SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID}}" \
  CODE_SIGN_STYLE=Automatic \
  >"${xcode_log}" 2>&1
xcode_status=$?
set -e

if [[ "${xcode_status}" != "0" ]]; then
  json "failed" "$(json_string "$(classify_xcode_failure "${xcode_log}")")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit "${xcode_status}"
fi

generated_xctestrun="$(find "${derived_data}" -name "*.xctestrun" -print -quit)"
if [[ -z "${generated_xctestrun}" ]]; then
  json "failed" "$(json_string "xctestrun_not_generated")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit 1
fi
xctestrun_path="$(dirname "${generated_xctestrun}")/SecureUpgradeAppAttestCapture-${capture_run_id}.xctestrun"

python3 - "${generated_xctestrun}" "${xctestrun_path}" "${capture_run_id}" \
  "${expected_bundle_id}" "${SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID}" <<'PY'
import plistlib
import sys

source, destination, capture_run_id, expected_bundle_id, team_id = sys.argv[1:]
with open(source, "rb") as f:
    xctestrun = plistlib.load(f)

capture_environment = {
    "SOYEHT_RUN_SECURE_UPGRADE_APP_ATTEST_CAPTURE": "1",
    "SOYEHT_SECURE_UPGRADE_APP_ATTEST_CAPTURE_RUN_ID": capture_run_id,
    "SOYEHT_EXPECTED_BUNDLE_ID": expected_bundle_id,
    "SOYEHT_SECURE_UPGRADE_APP_ATTEST_TEAM_ID": team_id,
}

for configuration in xctestrun.get("TestConfigurations", []):
    for target in configuration.get("TestTargets", []):
        for environment_key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            environment = target.setdefault(environment_key, {})
            environment.update(capture_environment)

with open(destination, "wb") as f:
    plistlib.dump(xctestrun, f)
PY

set +e
xcodebuild test-without-building \
  -xctestrun "${xctestrun_path}" \
  -destination "${SOYEHT_IOS_DEVICE_DESTINATION}" \
  -only-testing:SoyehtTests/SecureUpgradeAppAttestCaptureTests/testCaptureRealIphoneAppAttestPositiveFixture \
  -resultBundlePath "${result_bundle}" \
  >>"${xcode_log}" 2>&1
xcode_status=$?
set -e

if [[ "${xcode_status}" != "0" ]]; then
  json "failed" "$(json_string "$(classify_xcode_failure "${xcode_log}")")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit "${xcode_status}"
fi

set +e
xcrun devicectl device copy from \
  --device "${SOYEHT_IOS_DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${expected_bundle_id}" \
  --source "Documents/SecureUpgradeAppAttestCapture" \
  --destination "${download_dir}" \
  --quiet \
  --timeout 60 \
  >>"${copy_log}" 2>&1
copy_status=$?
set -e

if [[ "${copy_status}" != "0" ]]; then
  json "failed" "$(json_string "capture_output_download_failed")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit "${copy_status}"
fi

downloaded_fixture="$(find "${download_dir}" -type f -name "positive-fixture.json" -print -quit)"
downloaded_result="$(find "${download_dir}" -type f -name "capture-result.json" -print -quit)"
if [[ -z "${downloaded_result}" ]]; then
  json "failed" "$(json_string "downloaded_capture_result_missing")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit 1
fi

result_status="$(
  python3 - "${downloaded_result}" "${capture_run_id}" <<'PY'
import json
import sys

path, expected_run_id = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    result = json.load(f)

ok = (
    result.get("status") == "passed"
    and result.get("fixture_written") is True
    and result.get("capture_run_id") == expected_run_id
)
print("ok" if ok else "invalid")
PY
)"
if [[ "${result_status}" != "ok" ]]; then
  json "failed" "$(json_string "capture_result_not_current_pass")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit 1
fi

if [[ -z "${downloaded_fixture}" ]]; then
  json "failed" "$(json_string "downloaded_fixture_missing")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit 1
fi

fixture_status="$(
  python3 - "${downloaded_fixture}" "${capture_run_id}" <<'PY'
import json
import sys

path, expected_run_id = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    fixture = json.load(f)

ok = (
    fixture.get("contract") == "secure_upgrade_app_attest_positive_fixture_v1"
    and fixture.get("capture_run_id") == expected_run_id
)
print("ok" if ok else "invalid")
PY
)"
if [[ "${fixture_status}" != "ok" ]]; then
  json "failed" "$(json_string "fixture_not_current_capture")" "false" "$(json_string "not_run")" "$(json_string "${capture_run_id}")"
  exit 1
fi

install -m 600 "${downloaded_fixture}" "${fixture_path}"

rust_verifier="not_run"
if [[ -n "${THEYOS_DIR:-}" ]]; then
  theyos_dir="$(normalize_path "${THEYOS_DIR}")"
  verifier_log="${work_dir}/rust-verifier.log"
  set +e
  (
    cd "${theyos_dir}/admin/rust"
    SOYEHT_SECURE_UPGRADE_APP_ATTEST_FIXTURE="${fixture_path}" \
      SOYEHT_SECURE_UPGRADE_APP_ATTEST_CAPTURE_RUN_ID="${capture_run_id}" \
      cargo test -j 1 -p household-rs --test secure_upgrade_app_attest_bindings \
        real_iphone_app_attest_fixture_verifies_current_apple_chain \
        -- --ignored --nocapture
  ) >"${verifier_log}" 2>&1
  verifier_status=$?
  set -e
  if [[ "${verifier_status}" != "0" ]]; then
    json "failed" "$(json_string "rust_verifier_failed")" "true" "$(json_string "failed")" "$(json_string "${capture_run_id}")"
    exit "${verifier_status}"
  fi
  rust_verifier="passed"
fi

if [[ "${rust_verifier}" != "passed" ]]; then
  json "capture_only" "null" "true" "$(json_string "${rust_verifier}")" "$(json_string "${capture_run_id}")"
  exit 0
fi

json "passed" "null" "true" "$(json_string "${rust_verifier}")" "$(json_string "${capture_run_id}")"
