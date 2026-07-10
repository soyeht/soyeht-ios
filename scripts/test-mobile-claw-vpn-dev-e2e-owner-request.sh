#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

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
    "owner_present_required", "owner_acknowledged", "execution_authorized",
    "request_written", "app_launch_attempted", "relay_contact_attempted",
    "raw_values_printed",
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
assert payload["owner_acknowledged"] is False, payload
assert payload["execution_authorized"] is False, payload
assert payload["app_launch_attempted"] is False, payload
assert payload["relay_contact_attempted"] is False, payload
assert payload["raw_values_printed"] is False, payload
if expected_status == "owner_confirmation_required":
    assert payload["attempt_id"], payload
    assert payload["readiness_run_id"], payload
    assert payload["artifact_sha"], payload
    assert payload["request_written"] is True, payload
else:
    assert payload["attempt_id"] is None, payload
    assert payload["readiness_run_id"] is None, payload
    assert payload["artifact_sha"] is None, payload
    assert payload["request_written"] is False, payload
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
        printf 'private value leaked into request artifacts\n' >&2
        exit 1
      fi
    elif [[ "${path_or_value}" == *"${private_value}"* ]]; then
      printf 'private value leaked into request stdout\n' >&2
      exit 1
    fi
  done
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-mobile-claw-vpn-owner-request-test.XXXXXX")"
trap 'rm -rf "${tmp_root}"' EXIT

fake_bin="${tmp_root}/bin"
mkdir -p "${fake_bin}"
ledger="${tmp_root}/effect-ledger"
for binary in xcodebuild xcrun; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"%s"\nexit 97\n' \
    "${ledger}" >"${fake_bin}/${binary}"
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

test_repo="${tmp_root}/repo"
mkdir -p "${test_repo}/scripts"
for name in \
  mobile-claw-vpn-dev-e2e-env.sh \
  mobile-claw-vpn-dev-e2e-preflight.sh \
  mobile-claw-vpn-dev-e2e-runner.sh \
  mobile-claw-vpn-dev-e2e-owner-request.py \
  mobile-claw-vpn-dev-e2e-owner-request.sh; do
  cp -p "${script_dir}/${name}" "${test_repo}/scripts/${name}"
done
printf 'owner request fixture\n' >"${test_repo}/fixture.txt"
/usr/bin/git -C "${test_repo}" init -q -b main
/usr/bin/git -C "${test_repo}" config user.name 'Soyeht Test'
/usr/bin/git -C "${test_repo}" config user.email 'test@example.invalid'
/usr/bin/git -C "${test_repo}" add scripts fixture.txt
/usr/bin/git -C "${test_repo}" commit -q -m fixture
/usr/bin/git -C "${test_repo}" update-ref refs/remotes/origin/main HEAD

request_wrapper="${test_repo}/scripts/mobile-claw-vpn-dev-e2e-owner-request.sh"
request_python="${test_repo}/scripts/mobile-claw-vpn-dev-e2e-owner-request.py"

local_env_file="${tmp_root}/owner-flags-must-not-load.local"
cat >"${local_env_file}" <<EOF
SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_REQUEST=1
SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${tmp_root}/must-not-exist"
SOYEHT_IOS_DEVICE_DESTINATION="${private_device_destination}"
SOYEHT_IOS_DEVICE_ID="${private_device_id}"
SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID="${private_logical_device_id}"
SOYEHT_MOBILE_CLAW_VPN_CLAW_ID="${private_claw_id}"
EOF
output="$(
  env PATH="${fake_bin}:${PATH}" \
    SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE="${local_env_file}" \
    "${request_wrapper}"
)"
assert_json "${output}" "skipped" "owner_request_opt_in_not_set"
assert_no_private_values "${output}" value "${private_values[@]}"
test ! -e "${tmp_root}/must-not-exist"
test ! -e "${ledger}"
printf 'ok owner_request_is_explicit_and_not_loaded_from_local_env\n'

request_env=(
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

prepare_request() {
  local evidence_dir="$1"
  shift
  env -u SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE \
    "${request_env[@]}" \
    "$@" \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${evidence_dir}" \
    SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_REQUEST=1 \
    "${request_wrapper}"
}

argument_evidence="${tmp_root}/caller-selected-repo-evidence"
argument_output="$(
  env -u SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_ENV_FILE \
    "${request_env[@]}" \
    SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR="${argument_evidence}" \
    SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_REQUEST=1 \
    python3 "${request_python}" "${tmp_root}/caller-selected-repo"
)" || true
assert_json "${argument_output}" "failed" "owner_request_argument_refused"
test ! -e "${argument_evidence}"
test ! -e "${ledger}"
printf 'ok caller_cannot_select_repository_provenance\n'

evidence_ready="${tmp_root}/ready"
prepare_output="$(
  umask 0377
  prepare_request "${evidence_ready}"
)"
assert_json "${prepare_output}" "owner_confirmation_required" "null"
attempt_id="$(json_value "${prepare_output}" attempt_id)"
readiness_run_id="$(json_value "${prepare_output}" readiness_run_id)"
artifact_sha="$(json_value "${prepare_output}" artifact_sha)"
request_path="${evidence_ready}/mobile-claw-vpn-owner-request-${attempt_id}.json"
test -f "${request_path}"
test "$(stat -f '%Lp' "${request_path}")" = '600'
test "$(stat -f '%Lp' "${evidence_ready}")" = '700'
test "${artifact_sha}" = "$(/usr/bin/git -C "${test_repo}" rev-parse HEAD)"

python3 - \
  "${request_path}" \
  "${attempt_id}" \
  "${readiness_run_id}" \
  "${artifact_sha}" \
  "${private_device_destination}" \
  "${private_device_id}" \
  "${private_logical_device_id}" \
  "${private_claw_id}" <<'PY'
import hashlib
import json
import sys

(
    path,
    attempt_id,
    readiness_run_id,
    artifact_sha,
    destination,
    device_id,
    logical_device_id,
    claw_id,
) = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    request = json.load(handle)
expected_keys = {
    "contract", "status", "attempt_id", "readiness_run_id", "artifact_sha",
    "created_at_unix", "expires_at_unix", "bundle_id", "device_alias",
    "claw_alias", "relay_alias", "mesh_alias", "device_binding",
    "owner_present_required", "owner_acknowledged", "execution_authorized",
    "app_launch_attempted", "relay_contact_attempted", "raw_values_printed",
}
assert set(request) == expected_keys, request
assert request["contract"] == "mobile_claw_vpn_dev_owner_request_v1", request
assert request["status"] == "awaiting_owner_confirmation", request
assert request["attempt_id"] == attempt_id, request
assert request["readiness_run_id"] == readiness_run_id, request
assert request["artifact_sha"] == artifact_sha, request
assert request["expires_at_unix"] - request["created_at_unix"] == 300, request
digest = hashlib.sha256()
digest.update(b"soyeht-mobile-claw-vpn-owner-request-v1\0")
digest.update(attempt_id.encode("utf-8"))
for value in (destination, device_id, logical_device_id, claw_id):
    digest.update(b"\0")
    digest.update(value.encode("utf-8"))
assert request["device_binding"] == digest.hexdigest(), request
assert request["owner_present_required"] is True, request
assert request["owner_acknowledged"] is False, request
assert request["execution_authorized"] is False, request
assert request["app_launch_attempted"] is False, request
assert request["relay_contact_attempted"] is False, request
assert request["raw_values_printed"] is False, request
PY

assert_no_private_values "${prepare_output}" value "${private_values[@]}"
assert_no_private_values "${evidence_ready}" tree "${private_values[@]}"
test ! -e "${ledger}"
printf 'ok fresh_request_is_bound_and_non_authoritative\n'

second_output="$(prepare_request "${evidence_ready}")"
assert_json "${second_output}" "owner_confirmation_required" "null"
second_attempt_id="$(json_value "${second_output}" attempt_id)"
second_readiness_run_id="$(json_value "${second_output}" readiness_run_id)"
test "${second_attempt_id}" != "${attempt_id}"
test "${second_readiness_run_id}" != "${readiness_run_id}"
test -f "${request_path}"
test -f "${evidence_ready}/mobile-claw-vpn-owner-request-${second_attempt_id}.json"
test ! -e "${ledger}"
printf 'ok consecutive_requests_are_fresh_and_never_consumed_as_authority\n'

evidence_symlink="${tmp_root}/symlink-summary"
mkdir -m 700 "${evidence_symlink}"
summary_target="${tmp_root}/runner-summary-outside-evidence.json"
cp "${evidence_ready}/mobile-claw-vpn-dev-e2e-runner-summary.json" "${summary_target}"
chmod 600 "${summary_target}"
ln -s "${summary_target}" "${evidence_symlink}/mobile-claw-vpn-dev-e2e-runner-summary.json"
symlink_output="$(prepare_request "${evidence_symlink}")"
assert_json "${symlink_output}" "refused" "runner_previous_summary_mode_refused"
test ! -e "${ledger}"
printf 'ok symlinked_readiness_is_refused_before_request\n'

evidence_dirty="${tmp_root}/dirty-repo"
printf 'dirty\n' >>"${test_repo}/fixture.txt"
dirty_output="$(prepare_request "${evidence_dirty}")"
assert_json "${dirty_output}" "refused" "repository_not_clean"
test ! -e "${evidence_dirty}"
test ! -e "${ledger}"
/usr/bin/git -C "${test_repo}" restore fixture.txt

printf 'unmerged\n' >>"${test_repo}/fixture.txt"
/usr/bin/git -C "${test_repo}" add fixture.txt
/usr/bin/git -C "${test_repo}" commit -q -m unmerged
unmerged_output="$(prepare_request "${tmp_root}/unmerged-repo")"
assert_json "${unmerged_output}" "refused" "repository_head_not_merged_main"
test ! -e "${tmp_root}/unmerged-repo"
test ! -e "${ledger}"
printf 'ok repository_drift_is_refused_before_request\n'

/usr/bin/git -C "${test_repo}" update-ref refs/remotes/origin/main HEAD
cat >"${test_repo}/scripts/mobile-claw-vpn-dev-e2e-runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
fake_case="${OWNER_REQUEST_FAKE_CASE:-extra_stdout}"

if [[ "${fake_case}" == "runner_nonzero" ]]; then
  exit 9
fi
if [[ "${fake_case}" == "invalid_json" ]]; then
  printf '{bad json}\n'
  exit 0
fi

python3 - \
  "${SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR}" \
  "${fake_case}" \
  "${repo_root}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

evidence_dir = Path(sys.argv[1])
case = sys.argv[2]
repo_root = Path(sys.argv[3])
evidence_dir.mkdir(parents=True, exist_ok=True)
os.chmod(evidence_dir, 0o700)
summary_path = evidence_dir / "mobile-claw-vpn-dev-e2e-runner-summary.json"

if case == "reuse" and summary_path.exists():
    with open(summary_path, "r", encoding="utf-8") as handle:
        run_id = json.load(handle)["run_id"]
else:
    run_id = str(uuid.uuid4())

common = {
    "bundle_id": "com.soyeht.app.dev",
    "device_alias": "Device-D",
    "claw_alias": "Claw-M",
    "relay_alias": "Relay-R",
    "mesh_alias": "Mesh-C",
    "owner_present_required": True,
    "app_launch_attempted": False,
    "relay_contact_attempted": False,
    "raw_values_printed": False,
}
stdout = {
    "status": "ready_for_owner_present",
    "reason": None,
    "run_id": run_id,
    "preflight_status": "ready",
    "summary_written": True,
    **common,
}
summary = {
    "status": "ready_for_owner_present",
    "reason": None,
    "run_id": run_id,
    "preflight_status": "ready",
    "preflight_summary_observed": True,
    **common,
}
if case == "extra_stdout":
    stdout["unexpected"] = True
elif case == "bad_summary":
    summary["owner_present_required"] = False
elif case == "extra_summary":
    summary["unexpected"] = True
elif case == "raw_summary":
    summary["raw_values_printed"] = True
elif case == "raw_stdout":
    stdout["raw_values_printed"] = True
elif case == "stdout_status":
    stdout["status"] = "skipped"
elif case == "stdout_owner":
    stdout["owner_present_required"] = False
elif case == "stdout_summary_missing":
    stdout["summary_written"] = False
elif case == "stdout_app":
    stdout["app_launch_attempted"] = True
elif case == "stdout_relay":
    stdout["relay_contact_attempted"] = True
elif case == "stdout_bundle":
    stdout["bundle_id"] = "com.soyeht.app"
elif case == "stdout_alias":
    stdout["device_alias"] = "private-device-alias"
elif case == "stdout_run_id":
    stdout["run_id"] = "not-a-uuid"
elif case == "summary_status":
    summary["status"] = "skipped"
elif case == "summary_app":
    summary["app_launch_attempted"] = True
elif case == "summary_relay":
    summary["relay_contact_attempted"] = True
elif case == "summary_preflight":
    summary["preflight_status"] = "skipped"
elif case == "summary_evidence":
    summary["preflight_summary_observed"] = False
elif case == "summary_bundle":
    summary["bundle_id"] = "com.soyeht.app"
elif case == "summary_alias":
    summary["device_alias"] = "private-device-alias"
elif case == "summary_run_id":
    summary["run_id"] = "not-a-uuid"
elif case == "mismatched_run_ids":
    summary["run_id"] = str(uuid.uuid4())
elif case == "bad_stdout_preflight":
    stdout["preflight_status"] = "skipped"
elif case == "stdout_reason":
    stdout["reason"] = "unexpected"
elif case == "summary_reason":
    summary["reason"] = "unexpected"
elif case == "dirty_during_runner":
    with open(repo_root / "fixture.txt", "a", encoding="utf-8") as handle:
        handle.write("dirty during runner\n")
elif case == "clean_advance_during_runner":
    with open(repo_root / "fixture.txt", "a", encoding="utf-8") as handle:
        handle.write("clean advance during runner\n")
    subprocess.run(
        ["/usr/bin/git", "-C", str(repo_root), "add", "fixture.txt"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["/usr/bin/git", "-C", str(repo_root), "commit", "-q", "-m", "advance"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "/usr/bin/git",
            "-C",
            str(repo_root),
            "update-ref",
            "refs/remotes/origin/main",
            "HEAD",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

if case != "missing_summary":
    descriptor = os.open(
        summary_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        os.fchmod(handle.fileno(), 0o600)
        json.dump(summary, handle, sort_keys=True)
        handle.write("\n")
    if case == "mode":
        os.chmod(summary_path, 0o644)
    elif case == "old_mtime":
        os.utime(summary_path, (0, 0))
print(json.dumps(stdout, sort_keys=True))
PY
EOF
chmod 755 "${test_repo}/scripts/mobile-claw-vpn-dev-e2e-runner.sh"
/usr/bin/git -C "${test_repo}" add scripts/mobile-claw-vpn-dev-e2e-runner.sh
/usr/bin/git -C "${test_repo}" commit -q -m malformed-runner-fixture
/usr/bin/git -C "${test_repo}" update-ref refs/remotes/origin/main HEAD

for specification in \
  'runner_nonzero:failed:runner_command_failed' \
  'invalid_json:failed:runner_json_invalid' \
  'extra_stdout:refused:runner_stdout_schema_invalid' \
  'stdout_status:skipped:runner_not_ready_for_owner_present' \
  'bad_stdout_preflight:refused:runner_stdout_preflight_status_invalid' \
  'stdout_reason:refused:runner_stdout_reason_invalid' \
  'raw_stdout:refused:runner_raw_values_state_invalid' \
  'stdout_owner:refused:runner_owner_present_contract_invalid' \
  'stdout_summary_missing:refused:runner_ready_without_summary' \
  'stdout_app:refused:runner_app_launch_state_invalid' \
  'stdout_relay:refused:runner_relay_contact_state_invalid' \
  'stdout_bundle:refused:runner_bundle_id_not_dev_refused' \
  'stdout_alias:refused:runner_alias_mismatch' \
  'stdout_run_id:refused:runner_run_id_invalid' \
  'missing_summary:refused:runner_summary_missing' \
  'extra_summary:refused:runner_summary_schema_invalid' \
  'summary_status:refused:runner_summary_status_invalid' \
  'summary_reason:refused:runner_summary_reason_invalid' \
  'summary_preflight:refused:runner_summary_preflight_status_invalid' \
  'summary_evidence:refused:runner_summary_preflight_evidence_invalid' \
  'bad_summary:refused:runner_summary_owner_present_contract_invalid' \
  'summary_app:refused:runner_summary_app_launch_state_invalid' \
  'summary_relay:refused:runner_summary_relay_contact_state_invalid' \
  'raw_summary:refused:runner_summary_raw_values_state_invalid' \
  'summary_bundle:refused:runner_summary_bundle_id_not_dev_refused' \
  'summary_alias:refused:runner_summary_alias_mismatch' \
  'summary_run_id:refused:runner_summary_run_id_invalid' \
  'mismatched_run_ids:refused:runner_stdout_summary_run_id_mismatch' \
  'mode:refused:runner_summary_mode_refused' \
  'old_mtime:refused:runner_summary_not_fresh'; do
  fake_case="${specification%%:*}"
  remaining="${specification#*:}"
  expected_status="${remaining%%:*}"
  expected_reason="${remaining#*:}"
  evidence_case="${tmp_root}/runner-${fake_case}"
  case_exit=0
  case_output="$(
    prepare_request "${evidence_case}" OWNER_REQUEST_FAKE_CASE="${fake_case}"
  )" || case_exit=$?
  assert_json "${case_output}" "${expected_status}" "${expected_reason}"
  if [[ "${expected_status}" == "failed" ]]; then
    test "${case_exit}" = '1'
  else
    test "${case_exit}" = '0'
  fi
  if [[ -d "${evidence_case}" ]]; then
    test -z "$(find "${evidence_case}" -name 'mobile-claw-vpn-owner-request-*.json' -print -quit)"
  fi
done

evidence_reuse="${tmp_root}/runner-reuse"
mkdir -m 700 "${evidence_reuse}"
python3 - "${evidence_reuse}/mobile-claw-vpn-dev-e2e-runner-summary.json" <<'PY'
import json
import os
import sys
import uuid

descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    os.fchmod(handle.fileno(), 0o600)
    json.dump({"run_id": str(uuid.uuid4())}, handle)
    handle.write("\n")
PY
reuse_output="$(prepare_request "${evidence_reuse}" OWNER_REQUEST_FAKE_CASE='reuse')"
assert_json "${reuse_output}" "refused" "runner_run_id_not_fresh"
test -z "$(find "${evidence_reuse}" -name 'mobile-claw-vpn-owner-request-*.json' -print -quit)"

evidence_during_runner="${tmp_root}/dirty-during-runner"
drift_output="$(
  prepare_request \
    "${evidence_during_runner}" \
    OWNER_REQUEST_FAKE_CASE='dirty_during_runner'
)"
assert_json "${drift_output}" "refused" "repository_not_clean"
test -z "$(find "${evidence_during_runner}" -name 'mobile-claw-vpn-owner-request-*.json' -print -quit)"
/usr/bin/git -C "${test_repo}" restore fixture.txt

evidence_advance="${tmp_root}/clean-advance-during-runner"
advance_output="$(
  prepare_request \
    "${evidence_advance}" \
    OWNER_REQUEST_FAKE_CASE='clean_advance_during_runner'
)"
assert_json \
  "${advance_output}" \
  "refused" \
  "repository_artifact_changed_during_readiness"
test -z "$(find "${evidence_advance}" -name 'mobile-claw-vpn-owner-request-*.json' -print -quit)"
test ! -e "${ledger}"
printf 'ok malformed_stale_or_drifted_readiness_is_never_promoted_to_request\n'

attacker_repo="${tmp_root}/attacker-repo"
mkdir -p "${attacker_repo}"
/usr/bin/git -C "${attacker_repo}" init -q -b main
/usr/bin/git -C "${attacker_repo}" config user.name 'Soyeht Test'
/usr/bin/git -C "${attacker_repo}" config user.email 'test@example.invalid'
printf 'attacker-selected repository\n' >"${attacker_repo}/fixture.txt"
/usr/bin/git -C "${attacker_repo}" add fixture.txt
/usr/bin/git -C "${attacker_repo}" commit -q -m attacker-fixture
/usr/bin/git -C "${attacker_repo}" update-ref refs/remotes/origin/main HEAD

printf 'real repo remains authoritative\n' >>"${test_repo}/fixture.txt"
git_env_evidence="${tmp_root}/git-env-provenance"
git_env_output="$(
  prepare_request \
    "${git_env_evidence}" \
    GIT_DIR="${attacker_repo}/.git" \
    GIT_WORK_TREE="${attacker_repo}"
)"
assert_json "${git_env_output}" "refused" "repository_not_clean"
test ! -e "${git_env_evidence}"
/usr/bin/git -C "${test_repo}" restore fixture.txt
test ! -e "${ledger}"
printf 'ok git_environment_cannot_select_repository_provenance\n'

python3 - "${request_python}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
for forbidden in (
    "def " + "execute(",
    "ready_for_dev_" + "control_plane_run",
    "owner_ack_" + "required",
    "execution_" + "gate",
    "ACK" + "_ENV",
    "RUN" + "_ENV",
    "xcodebuild",
    "xcrun",
):
    assert forbidden not in source, forbidden
assert '"owner_acknowledged": False' in source
assert '"execution_authorized": False' in source
assert 'repo_root = SCRIPT_DIR.parent' in source
assert 'if not key.startswith("GIT_")' in source
PY
test ! -e "${ledger}"
printf 'ok source_has_no_ack_execute_or_runtime_authority\n'

printf 'mobile Claw VPN DEV owner request self-test passed (9/9)\n'
