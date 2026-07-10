#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
preflight_script="${script_dir}/mobile-claw-vpn-dev-e2e-preflight.sh"

assert_json() {
  local output="$1"
  local expected_status="$2"
  local expected_reason="$3"
  local expected_summary="$4"

  python3 - "${output}" "${expected_status}" "${expected_reason}" "${expected_summary}" <<'PY'
import json
import sys

raw, expected_status, expected_reason, expected_summary = sys.argv[1:]
payload = json.loads(raw)
assert payload["status"] == expected_status, payload
if expected_reason == "null":
    assert payload["reason"] is None, payload
else:
    assert payload["reason"] == expected_reason, payload
assert str(payload["summary_written"]).lower() == expected_summary, payload
assert payload["raw_values_printed"] is False, payload
PY
}

assert_case() {
  local name="$1"
  local expected_status="$2"
  local expected_reason="$3"
  local expected_summary="$4"
  shift 4

  local output
  output="$("$@")"
  assert_json "${output}" "${expected_status}" "${expected_reason}" "${expected_summary}"
  printf 'ok %s\n' "${name}"
}

assert_not_contains_private_values() {
  local value_path="$1"
  shift

  for private_value in "$@"; do
    if grep -R -F "${private_value}" "${value_path}" >/dev/null 2>&1; then
      printf 'private value leaked: %s\n' "${private_value}" >&2
      exit 1
    fi
  done
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-mobile-claw-vpn-preflight-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT

private_device_destination='platform=iOS,id=private-device-udid'
private_device_id='private-device-id'
private_claw_id='private-claw-id'

assert_case "skips_without_opt_in" "skipped" \
  "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_not_set" "false" \
  "${preflight_script}"

assert_case "refuses_non_public_alias" "refused" \
  "device_alias_not_public_refused" "false" \
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS='real-device-name' \
    "${preflight_script}"

assert_case "refuses_production_bundle_id" "refused" \
  "bundle_id_not_dev_refused" "false" \
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID='com.soyeht.app' \
    "${preflight_script}"

assert_case "skips_without_evidence_dir" "skipped" \
  "evidence_dir_missing" "false" \
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    "${preflight_script}"

assert_case "refuses_evidence_dir_inside_repo" "refused" \
  "evidence_dir_inside_repo_refused" "false" \
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${repo_root}/mobile-claw-vpn-evidence" \
    "${preflight_script}"

evidence_missing_device="${tmp_root}/missing-device"
assert_case "skips_without_explicit_device_destination" "skipped" \
  "ios_device_destination_missing_explicit_selection_required" "false" \
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_missing_device}" \
    "${preflight_script}"

evidence_ready="${tmp_root}/ready"
ready_output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_ready}" \
    SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}" \
    SOYEHT_IOS_DEVICE_ID="${private_device_id}" \
    SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_device_id}" \
    SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}" \
    "${preflight_script}"
)"
assert_json "${ready_output}" "ready" "null" "true"
for private_value in "${private_device_destination}" "${private_device_id}" "${private_claw_id}"; do
  if [[ "${ready_output}" == *"${private_value}"* ]]; then
    printf 'private value leaked in stdout: %s\n' "${private_value}" >&2
    exit 1
  fi
done
summary_path="${evidence_ready}/mobile-claw-vpn-dev-e2e-preflight-summary.json"
test -f "${summary_path}"

assert_not_contains_private_values "${evidence_ready}" \
  "${private_device_destination}" \
  "${private_device_id}" \
  "${private_claw_id}"

python3 - "${summary_path}" <<'PY'
import json
import os
import stat
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
assert payload["status"] == "ready", payload
assert payload["device_alias"] == "Device-D", payload
assert payload["claw_alias"] == "Claw-M", payload
assert payload["relay_alias"] == "Relay-R", payload
assert payload["mesh_alias"] == "Mesh-C", payload
assert payload["raw_values_printed"] is False, payload
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
parent_mode = stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)
assert parent_mode == 0o700, oct(parent_mode)
PY

printf 'ok ready_summary_is_redacted\n'
