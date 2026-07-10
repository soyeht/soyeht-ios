#!/usr/bin/env bash
set -euo pipefail

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
source "${script_dir}/mobile-claw-vpn-dev-e2e-env.sh"
load_mobile_claw_vpn_dev_e2e_env "${repo_root}"
preflight_bin="${SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_BIN:-${script_dir}/mobile-claw-vpn-dev-e2e-preflight.sh}"

json() {
  printf '{"status":"%s","reason":%s,"run_id":null,"preflight_status":%s,"summary_written":%s,"bundle_id":"com.soyeht.app.dev","device_alias":"Device-D","claw_alias":"Claw-M","relay_alias":"Relay-R","mesh_alias":"Mesh-C","owner_present_required":true,"app_launch_attempted":false,"relay_contact_attempted":false,"raw_values_printed":false}\n' \
    "$1" "$2" "$3" "$4"
}

if [[ "${SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E:-}" != "1" ]]; then
  json "skipped" "$(json_string "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_not_set")" "null" "false"
  exit 0
fi

preflight_output=""
if ! preflight_output="$(
  env SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT=1 \
    "${preflight_bin}" 2>/dev/null
)"; then
  json "failed" "$(json_string "preflight_command_failed")" "null" "false"
  exit 0
fi

python3 - "${preflight_output}" "${repo_root}" <<'PY'
import json
import os
import stat
import sys
import uuid

raw, repo_root = sys.argv[1:]
repo_root = os.path.realpath(repo_root)

DEVICE_ALIASES = {"Device-D"}
CLAW_ALIASES = {"Claw-M", "Claw-L"}
RELAY_ALIASES = {"Relay-R"}
MESH_ALIASES = {"Mesh-C"}


def emit(status, reason, preflight_status=None, summary_written=False, aliases=None, run_id=None):
    aliases = aliases or {}
    payload = {
        "status": status,
        "reason": reason,
        "run_id": run_id,
        "preflight_status": preflight_status,
        "summary_written": summary_written,
        "bundle_id": aliases.get("bundle_id", "com.soyeht.app.dev"),
        "device_alias": aliases.get("device_alias", "Device-D"),
        "claw_alias": aliases.get("claw_alias", "Claw-M"),
        "relay_alias": aliases.get("relay_alias", "Relay-R"),
        "mesh_alias": aliases.get("mesh_alias", "Mesh-C"),
        "owner_present_required": True,
        "app_launch_attempted": False,
        "relay_contact_attempted": False,
        "raw_values_printed": False,
    }
    print(json.dumps(payload, sort_keys=True))


def public_aliases(payload):
    return {
        "bundle_id": payload.get("bundle_id") if payload.get("bundle_id") == "com.soyeht.app.dev" else "com.soyeht.app.dev",
        "device_alias": payload.get("device_alias") if payload.get("device_alias") in DEVICE_ALIASES else "Device-D",
        "claw_alias": payload.get("claw_alias") if payload.get("claw_alias") in CLAW_ALIASES else "Claw-M",
        "relay_alias": payload.get("relay_alias") if payload.get("relay_alias") in RELAY_ALIASES else "Relay-R",
        "mesh_alias": payload.get("mesh_alias") if payload.get("mesh_alias") in MESH_ALIASES else "Mesh-C",
    }


try:
    preflight = json.loads(raw)
except json.JSONDecodeError:
    emit("failed", "preflight_json_invalid")
    raise SystemExit(0)

aliases = public_aliases(preflight)
preflight_status = preflight.get("status")

if preflight_status != "ready":
    emit("skipped", "preflight_not_ready", str(preflight_status or "missing"), False, aliases)
    raise SystemExit(0)

if preflight.get("summary_written") is not True:
    emit("refused", "preflight_ready_without_summary", "ready", False, aliases)
    raise SystemExit(0)

if preflight.get("raw_values_printed") is not False:
    emit("refused", "preflight_raw_values_printed_refused", "ready", False, aliases)
    raise SystemExit(0)

if preflight.get("bundle_id") != "com.soyeht.app.dev":
    emit("refused", "preflight_bundle_id_not_dev_refused", "ready", False, aliases)
    raise SystemExit(0)

if (
    preflight.get("device_alias") not in DEVICE_ALIASES
    or preflight.get("claw_alias") not in CLAW_ALIASES
    or preflight.get("relay_alias") not in RELAY_ALIASES
    or preflight.get("mesh_alias") not in MESH_ALIASES
):
    emit("refused", "preflight_alias_not_public_refused", "ready", False, aliases)
    raise SystemExit(0)

evidence_dir_raw = os.environ.get("SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR", "")
if not evidence_dir_raw:
    emit("refused", "evidence_dir_missing_after_ready_preflight", "ready", False, aliases)
    raise SystemExit(0)

evidence_dir = os.path.realpath(os.path.expanduser(evidence_dir_raw))
if evidence_dir == repo_root or evidence_dir.startswith(repo_root + os.sep):
    emit("refused", "evidence_dir_inside_repo_refused", "ready", False, aliases)
    raise SystemExit(0)

preflight_summary = os.path.join(evidence_dir, "mobile-claw-vpn-dev-e2e-preflight-summary.json")
if not os.path.isfile(preflight_summary):
    emit("refused", "preflight_summary_missing", "ready", False, aliases)
    raise SystemExit(0)

if stat.S_IMODE(os.stat(evidence_dir).st_mode) != 0o700:
    emit("refused", "evidence_dir_mode_refused", "ready", False, aliases)
    raise SystemExit(0)

if stat.S_IMODE(os.stat(preflight_summary).st_mode) != 0o600:
    emit("refused", "preflight_summary_mode_refused", "ready", False, aliases)
    raise SystemExit(0)

summary = {
    "status": "ready_for_owner_present",
    "reason": None,
    "run_id": str(uuid.uuid4()),
    "preflight_status": "ready",
    "preflight_summary_observed": True,
    "bundle_id": "com.soyeht.app.dev",
    "device_alias": aliases["device_alias"],
    "claw_alias": aliases["claw_alias"],
    "relay_alias": aliases["relay_alias"],
    "mesh_alias": aliases["mesh_alias"],
    "owner_present_required": True,
    "app_launch_attempted": False,
    "relay_contact_attempted": False,
    "raw_values_printed": False,
}

summary_path = os.path.join(evidence_dir, "mobile-claw-vpn-dev-e2e-runner-summary.json")
try:
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, sort_keys=True)
        f.write("\n")
    os.chmod(summary_path, 0o600)
except OSError:
    emit("failed", "runner_summary_write_failed", "ready", False, aliases)
    raise SystemExit(0)

emit(
    "ready_for_owner_present",
    None,
    "ready",
    True,
    aliases,
    run_id=summary["run_id"],
)
PY
