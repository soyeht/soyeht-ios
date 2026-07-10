#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
gate_wrapper="${script_dir}/mobile-claw-vpn-dev-e2e-owner-gate.sh"
gate_python="${script_dir}/mobile-claw-vpn-dev-e2e-owner-gate.py"

assert_json() {
  local output="$1"
  local expected_status="$2"
  local expected_reason="$3"

  python3 - "${output}" "${expected_status}" "${expected_reason}" <<'PY'
import json
import sys

raw, expected_status, expected_reason = sys.argv[1:]
payload = json.loads(raw)
expected_keys = {
    "status", "reason", "attempt_id", "readiness_run_id", "artifact_sha",
    "bundle_id", "device_alias", "claw_alias", "relay_alias", "mesh_alias",
    "owner_present_required", "owner_acknowledged", "execution_gate_written",
    "app_launch_attempted", "relay_contact_attempted", "raw_values_printed",
}
assert set(payload) == expected_keys, payload
assert payload["status"] == expected_status, payload
if expected_reason == "null":
    assert payload["reason"] is None, payload
else:
    assert payload["reason"] == expected_reason, payload
assert payload["bundle_id"] == "com.soyeht.app.dev", payload
assert payload["device_alias"] == "Device-D", payload
assert payload["claw_alias"] == "Claw-M", payload
assert payload["relay_alias"] == "Relay-R", payload
assert payload["mesh_alias"] == "Mesh-C", payload
assert payload["owner_present_required"] is True, payload
assert payload["app_launch_attempted"] is False, payload
assert payload["relay_contact_attempted"] is False, payload
assert payload["raw_values_printed"] is False, payload
if expected_status == "owner_ack_required":
    assert payload["attempt_id"], payload
    assert payload["readiness_run_id"], payload
    assert payload["artifact_sha"], payload
    assert payload["owner_acknowledged"] is False, payload
    assert payload["execution_gate_written"] is False, payload
elif expected_status == "ready_for_dev_control_plane_run":
    assert payload["attempt_id"], payload
    assert payload["readiness_run_id"], payload
    assert payload["artifact_sha"], payload
    assert payload["owner_acknowledged"] is True, payload
    assert payload["execution_gate_written"] is True, payload
else:
    assert payload["attempt_id"] is None, payload
    assert payload["readiness_run_id"] is None, payload
    assert payload["artifact_sha"] is None, payload
    assert payload["owner_acknowledged"] is False, payload
    assert payload["execution_gate_written"] is False, payload
PY
}

json_value() {
  local output="$1"
  local key="$2"
  python3 - "${output}" "${key}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload[sys.argv[2]])
PY
}

assert_no_private_values() {
  local path_or_value="$1"
  local mode="$2"
  shift 2

  for private_value in "$@"; do
    if [[ "${mode}" == "tree" ]]; then
      if grep -R -F "${private_value}" "${path_or_value}" >/dev/null 2>&1; then
        printf 'private value leaked into gate artifacts\n' >&2
        exit 1
      fi
    elif [[ "${path_or_value}" == *"${private_value}"* ]]; then
      printf 'private value leaked into gate stdout\n' >&2
      exit 1
    fi
  done
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-mobile-claw-vpn-owner-gate-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT

fake_bin="${tmp_root}/bin"
mkdir -p "${fake_bin}"
ledger="${tmp_root}/effect-ledger"
for binary in xcodebuild xcrun; do
  printf '#!/usr/bin/env bash\nprintf "%s\\n" "$0" >>"%s"\nexit 97\n' \
    "${binary}" "${ledger}" >"${fake_bin}/${binary}"
  chmod +x "${fake_bin}/${binary}"
done

private_device_destination='platform=iOS,id=private-device-id'
private_device_id='private-device-id'
private_logical_device_id='private-device-d-id'
private_claw_id='private-claw-id'
private_values=(
  "${private_device_destination}"
  "${private_device_id}"
  "${private_logical_device_id}"
  "${private_claw_id}"
)

local_env_file="${tmp_root}/owner-flags-must-not-load.local"
cat >"${local_env_file}" <<EOF
SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE=1
SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE=1
SOYEHT_MOBILE_CLAW_VPN_OWNER_PRESENT_ACK=private-ack-value
SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${tmp_root}/must-not-exist"
SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}"
SOYEHT_IOS_DEVICE_ID="${private_device_id}"
SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_logical_device_id}"
SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}"
EOF
output="$(
  env PATH="${fake_bin}:${PATH}" \
    SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE="${local_env_file}" \
    "${gate_wrapper}"
)"
assert_json "${output}" "skipped" "owner_gate_opt_in_not_set"
assert_no_private_values "${output}" value "${private_values[@]}" 'private-ack-value'
test ! -e "${tmp_root}/must-not-exist"
test ! -e "${ledger}"
printf 'ok owner_gate_is_explicit_and_not_loaded_from_local_env\n'

test_repo="${tmp_root}/repo"
mkdir -p "${test_repo}"
/usr/bin/git -C "${test_repo}" init -q -b main
/usr/bin/git -C "${test_repo}" config user.name 'Soyeht Test'
/usr/bin/git -C "${test_repo}" config user.email 'test@example.invalid'
printf 'owner gate fixture\n' >"${test_repo}/fixture.txt"
/usr/bin/git -C "${test_repo}" add fixture.txt
/usr/bin/git -C "${test_repo}" commit -q -m fixture
/usr/bin/git -C "${test_repo}" update-ref refs/remotes/origin/main HEAD

gate_env=(
  PATH="${fake_bin}:${PATH}"
  SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID='com.soyeht.app.dev'
  SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}"
  SOYEHT_IOS_DEVICE_ID="${private_device_id}"
  SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_logical_device_id}"
  SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}"
  SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS='Device-D'
  SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS='Claw-M'
  SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS='Relay-R'
  SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS='Mesh-C'
)

prepare_gate() {
  local evidence_dir="$1"
  env "${gate_env[@]}" \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_dir}" \
    SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE=1 \
    python3 "${gate_python}" "${test_repo}"
}

execute_gate() {
  local evidence_dir="$1"
  local attempt_id="$2"
  shift 2
  env "${gate_env[@]}" "$@" \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_dir}" \
    SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE=1 \
    SOYEHT_MOBILE_CLAW_VPN_OWNER_PRESENT_ACK="${attempt_id}" \
    python3 "${gate_python}" "${test_repo}"
}

evidence_ready="${tmp_root}/ready"
prepare_output="$(prepare_gate "${evidence_ready}")"
assert_json "${prepare_output}" "owner_ack_required" "null"
attempt_id="$(json_value "${prepare_output}" attempt_id)"
readiness_run_id="$(json_value "${prepare_output}" readiness_run_id)"
request_path="${evidence_ready}/mobile-claw-vpn-owner-request-${attempt_id}.json"
test -f "${request_path}"
test "$(stat -f '%Lp' "${request_path}")" = '600'
test "$(stat -f '%Lp' "${evidence_ready}")" = '700'

execute_output="$(execute_gate "${evidence_ready}" "${attempt_id}")"
assert_json "${execute_output}" "ready_for_dev_control_plane_run" "null"
test "$(json_value "${execute_output}" readiness_run_id)" = "${readiness_run_id}"
gate_path="${evidence_ready}/mobile-claw-vpn-owner-execution-gate-${attempt_id}.json"
acknowledged_path="${evidence_ready}/mobile-claw-vpn-owner-acknowledged-${attempt_id}.json"
test -f "${gate_path}"
test -f "${acknowledged_path}"
test ! -f "${request_path}"
test "$(stat -f '%Lp' "${gate_path}")" = '600'
test "$(stat -f '%Lp' "${acknowledged_path}")" = '600'
assert_no_private_values "${prepare_output}${execute_output}" value "${private_values[@]}"
assert_no_private_values "${evidence_ready}" tree "${private_values[@]}"
test ! -e "${ledger}"
printf 'ok fresh_owner_ack_writes_single_use_execution_gate\n'

replay_output="$(execute_gate "${evidence_ready}" "${attempt_id}")"
assert_json "${replay_output}" "refused" "owner_request_not_found_or_already_consumed"
test ! -e "${ledger}"
printf 'ok consumed_owner_ack_cannot_be_replayed\n'

evidence_stale="${tmp_root}/stale"
stale_prepare="$(prepare_gate "${evidence_stale}")"
stale_attempt="$(json_value "${stale_prepare}" attempt_id)"
python3 - "${evidence_stale}/mobile-claw-vpn-owner-request-${stale_attempt}.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
payload["expires_at_unix"] = 0
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
stale_output="$(execute_gate "${evidence_stale}" "${stale_attempt}")"
assert_json "${stale_output}" "refused" "owner_request_expired"
test ! -e "${evidence_stale}/mobile-claw-vpn-owner-execution-gate-${stale_attempt}.json"
test ! -e "${ledger}"
printf 'ok stale_owner_request_is_refused_before_effect\n'

evidence_mismatch="${tmp_root}/device-mismatch"
mismatch_prepare="$(prepare_gate "${evidence_mismatch}")"
mismatch_attempt="$(json_value "${mismatch_prepare}" attempt_id)"
mismatch_output="$(
  execute_gate "${evidence_mismatch}" "${mismatch_attempt}" \
    SOYEHT_IOS_DEVICE_DESTINATION='platform=iOS,id=other-device-id' \
    SOYEHT_IOS_DEVICE_ID='other-device-id'
)"
assert_json "${mismatch_output}" "refused" "owner_request_device_binding_mismatch"
test ! -e "${evidence_mismatch}/mobile-claw-vpn-owner-execution-gate-${mismatch_attempt}.json"
test ! -e "${ledger}"
printf 'ok device_binding_mismatch_is_refused_before_effect\n'

evidence_readiness="${tmp_root}/readiness-mismatch"
readiness_prepare="$(prepare_gate "${evidence_readiness}")"
readiness_attempt="$(json_value "${readiness_prepare}" attempt_id)"
python3 - "${evidence_readiness}/mobile-claw-vpn-dev-e2e-runner-summary.json" <<'PY'
import json
import os
import sys
import uuid

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
payload["run_id"] = str(uuid.uuid4())
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
readiness_output="$(execute_gate "${evidence_readiness}" "${readiness_attempt}")"
assert_json "${readiness_output}" "refused" "runner_readiness_run_id_changed"
test ! -e "${evidence_readiness}/mobile-claw-vpn-owner-execution-gate-${readiness_attempt}.json"
test ! -e "${ledger}"
printf 'ok changed_readiness_run_id_is_refused_before_effect\n'

evidence_dirty="${tmp_root}/dirty-repo"
dirty_prepare="$(prepare_gate "${evidence_dirty}")"
dirty_attempt="$(json_value "${dirty_prepare}" attempt_id)"
printf 'dirty\n' >>"${test_repo}/fixture.txt"
dirty_output="$(execute_gate "${evidence_dirty}" "${dirty_attempt}")"
assert_json "${dirty_output}" "refused" "repository_not_clean"
test ! -e "${evidence_dirty}/mobile-claw-vpn-owner-execution-gate-${dirty_attempt}.json"
test ! -e "${ledger}"
printf 'ok repository_drift_is_refused_before_effect\n'

printf 'mobile Claw VPN DEV owner gate self-test passed (7/7)\n'
