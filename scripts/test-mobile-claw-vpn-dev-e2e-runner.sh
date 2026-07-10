#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
runner_script="${script_dir}/mobile-claw-vpn-dev-e2e-runner.sh"

assert_json() {
  local output="$1"
  local expected_status="$2"
  local expected_reason="$3"
  local expected_preflight_status="$4"
  local expected_summary="$5"

  python3 - "${output}" "${expected_status}" "${expected_reason}" "${expected_preflight_status}" "${expected_summary}" <<'PY'
import json
import sys

raw, expected_status, expected_reason, expected_preflight_status, expected_summary = sys.argv[1:]
payload = json.loads(raw)
assert payload["status"] == expected_status, payload
if expected_reason == "null":
    assert payload["reason"] is None, payload
else:
    assert payload["reason"] == expected_reason, payload
if expected_preflight_status == "null":
    assert payload["preflight_status"] is None, payload
else:
    assert payload["preflight_status"] == expected_preflight_status, payload
assert str(payload["summary_written"]).lower() == expected_summary, payload
assert payload["owner_present_required"] is True, payload
assert payload["app_launch_attempted"] is False, payload
assert payload["relay_contact_attempted"] is False, payload
assert payload["raw_values_printed"] is False, payload
if expected_status == "ready_for_owner_present":
    assert isinstance(payload["run_id"], str) and payload["run_id"], payload
else:
    assert payload["run_id"] is None, payload
PY
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

write_fake_preflight() {
  local path="$1"
  local body="$2"

  cat >"${path}" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '${body}'
SH
  chmod +x "${path}"
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-mobile-claw-vpn-runner-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT

private_device_destination='platform=iOS,id=private-device-udid'
private_device_id='private-device-id'
private_claw_id='private-claw-id'

output="$("${runner_script}")"
assert_json "${output}" "skipped" \
  "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_not_set" "null" "false"
printf 'ok skips_without_runner_opt_in\n'

fake_skipped="${tmp_root}/fake-skipped-preflight.sh"
write_fake_preflight "${fake_skipped}" \
  '{"status":"skipped","reason":"evidence_dir_missing","summary_written":false,"bundle_id":"com.soyeht.app.dev","device_alias":"Device-D","claw_alias":"Claw-M","relay_alias":"Relay-R","mesh_alias":"Mesh-C","raw_values_printed":false}'
output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1 \
    SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_BIN="${fake_skipped}" \
    "${runner_script}"
)"
assert_json "${output}" "skipped" "preflight_not_ready" "skipped" "false"
printf 'ok skipped_preflight_is_not_ready\n'

fake_refused="${tmp_root}/fake-refused-preflight.sh"
write_fake_preflight "${fake_refused}" \
  '{"status":"refused","reason":"bundle_id_not_dev_refused","summary_written":false,"bundle_id":"com.soyeht.app.dev","device_alias":"Device-D","claw_alias":"Claw-M","relay_alias":"Relay-R","mesh_alias":"Mesh-C","raw_values_printed":false}'
output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1 \
    SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_BIN="${fake_refused}" \
    "${runner_script}"
)"
assert_json "${output}" "skipped" "preflight_not_ready" "refused" "false"
printf 'ok refused_preflight_is_not_ready\n'

fake_ready_no_summary="${tmp_root}/fake-ready-no-summary-preflight.sh"
write_fake_preflight "${fake_ready_no_summary}" \
  '{"status":"ready","reason":null,"summary_written":false,"bundle_id":"com.soyeht.app.dev","device_alias":"Device-D","claw_alias":"Claw-M","relay_alias":"Relay-R","mesh_alias":"Mesh-C","raw_values_printed":false}'
output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1 \
    SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_BIN="${fake_ready_no_summary}" \
    "${runner_script}"
)"
assert_json "${output}" "refused" "preflight_ready_without_summary" "ready" "false"
printf 'ok ready_without_summary_is_refused\n'

evidence_ready="${tmp_root}/ready"
output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1 \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_ready}" \
    SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}" \
    SOYEHT_IOS_DEVICE_ID="${private_device_id}" \
    SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_device_id}" \
    SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}" \
    "${runner_script}"
)"
assert_json "${output}" "ready_for_owner_present" "null" "ready" "true"
for private_value in "${private_device_destination}" "${private_device_id}" "${private_claw_id}"; do
  if [[ "${output}" == *"${private_value}"* ]]; then
    printf 'private value leaked in stdout: %s\n' "${private_value}" >&2
    exit 1
  fi
done

runner_summary="${evidence_ready}/mobile-claw-vpn-dev-e2e-runner-summary.json"
preflight_summary="${evidence_ready}/mobile-claw-vpn-dev-e2e-preflight-summary.json"
test -f "${runner_summary}"
test -f "${preflight_summary}"

assert_not_contains_private_values "${evidence_ready}" \
  "${private_device_destination}" \
  "${private_device_id}" \
  "${private_claw_id}"

python3 - "${output}" "${runner_summary}" "${preflight_summary}" <<'PY'
import json
import os
import stat
import sys

raw, runner_path, preflight_path = sys.argv[1:]
stdout = json.loads(raw)
with open(runner_path, "r", encoding="utf-8") as f:
    runner = json.load(f)
with open(preflight_path, "r", encoding="utf-8") as f:
    preflight = json.load(f)
assert runner["status"] == "ready_for_owner_present", runner
assert stdout["run_id"] == runner["run_id"], (stdout, runner)
assert runner["preflight_status"] == "ready", runner
assert runner["owner_present_required"] is True, runner
assert runner["app_launch_attempted"] is False, runner
assert runner["relay_contact_attempted"] is False, runner
assert runner["raw_values_printed"] is False, runner
assert runner["device_alias"] == "Device-D", runner
assert runner["claw_alias"] == "Claw-M", runner
assert runner["relay_alias"] == "Relay-R", runner
assert runner["mesh_alias"] == "Mesh-C", runner
assert preflight["status"] == "ready", preflight
runner_mode = stat.S_IMODE(os.stat(runner_path).st_mode)
preflight_mode = stat.S_IMODE(os.stat(preflight_path).st_mode)
parent_mode = stat.S_IMODE(os.stat(os.path.dirname(runner_path)).st_mode)
assert runner_mode == 0o600, oct(runner_mode)
assert preflight_mode == 0o600, oct(preflight_mode)
assert parent_mode == 0o700, oct(parent_mode)
PY

printf 'ok ready_writes_sanitized_owner_present_summary\n'

evidence_env_file="${tmp_root}/runner ready from env file"
env_file="${tmp_root}/runner-mobile-claw-vpn.local"
cat >"${env_file}" <<EOF
SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1
SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E=1
SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_env_file}"
SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}"
SOYEHT_IOS_DEVICE_ID="${private_device_id}"
SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_device_id}"
SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}"
PRIVATE_VALUE_THAT_MUST_NOT_LOAD=private-ignored-value
EOF
env_file_output="$(
  env SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE="${env_file}" \
    "${runner_script}"
)"
assert_json "${env_file_output}" "ready_for_owner_present" "null" "ready" "true"
for private_value in "${private_device_destination}" "${private_device_id}" "${private_claw_id}" "private-ignored-value"; do
  if [[ "${env_file_output}" == *"${private_value}"* ]]; then
    printf 'private value leaked in env-file stdout: %s\n' "${private_value}" >&2
    exit 1
  fi
done

assert_not_contains_private_values "${evidence_env_file}" \
  "${private_device_destination}" \
  "${private_device_id}" \
  "${private_claw_id}" \
  "private-ignored-value"

python3 - "${env_file_output}" "${evidence_env_file}/mobile-claw-vpn-dev-e2e-runner-summary.json" <<'PY'
import json
import os
import stat
import sys

raw, path = sys.argv[1:]
stdout = json.loads(raw)
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
assert payload["status"] == "ready_for_owner_present", payload
assert stdout["run_id"] == payload["run_id"], (stdout, payload)
assert payload["raw_values_printed"] is False, payload
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
PY

printf 'ok ready_from_local_env_file_is_redacted\n'
