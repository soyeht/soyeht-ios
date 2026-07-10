#!/usr/bin/env bash
set -euo pipefail

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

normalize_path() {
  python3 -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"

json() {
  printf '{"status":"%s","reason":%s,"summary_written":%s,"bundle_id":%s,"device_alias":%s,"claw_alias":%s,"relay_alias":%s,"mesh_alias":%s,"raw_values_printed":false}\n' \
    "$1" "$2" "$3" "$(json_string "$4")" "$(json_string "$5")" \
    "$(json_string "$6")" "$(json_string "$7")" "$(json_string "$8")"
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

  if is_inside_repo "${dir}"; then
    json "refused" "$(json_string "evidence_dir_inside_repo_refused")" "false" \
      "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
    exit 0
  fi
  if [[ -e "${dir}" && ! -d "${dir}" ]]; then
    json "refused" "$(json_string "evidence_dir_not_directory")" "false" \
      "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
    exit 0
  fi
  mkdir -p "${dir}"
  if [[ ! -O "${dir}" ]]; then
    json "refused" "$(json_string "evidence_dir_not_owned")" "false" \
      "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
    exit 0
  fi
  if ! chmod 700 "${dir}"; then
    json "refused" "$(json_string "evidence_dir_chmod_failed")" "false" \
      "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
    exit 0
  fi
}

is_device_alias() {
  case "$1" in
    Device-D) return 0 ;;
    *) return 1 ;;
  esac
}

is_claw_alias() {
  case "$1" in
    Claw-M|Claw-L) return 0 ;;
    *) return 1 ;;
  esac
}

is_relay_alias() {
  case "$1" in
    Relay-R) return 0 ;;
    *) return 1 ;;
  esac
}

is_mesh_alias() {
  case "$1" in
    Mesh-C) return 0 ;;
    *) return 1 ;;
  esac
}

bundle_id="${SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID:-com.soyeht.app.dev}"
device_alias="${SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS:-Device-D}"
claw_alias="${SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS:-Claw-M}"
relay_alias="${SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS:-Relay-R}"
mesh_alias="${SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS:-Mesh-C}"

if [[ "${SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT:-}" != "1" ]]; then
  json "skipped" "$(json_string "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_not_set")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

if ! is_device_alias "${device_alias}"; then
  json "refused" "$(json_string "device_alias_not_public_refused")" "false" \
    "${bundle_id}" "Device-D" "Claw-M" "Relay-R" "Mesh-C"
  exit 0
fi

if ! is_claw_alias "${claw_alias}"; then
  json "refused" "$(json_string "claw_alias_not_public_refused")" "false" \
    "${bundle_id}" "Device-D" "Claw-M" "Relay-R" "Mesh-C"
  exit 0
fi

if ! is_relay_alias "${relay_alias}"; then
  json "refused" "$(json_string "relay_alias_not_public_refused")" "false" \
    "${bundle_id}" "Device-D" "Claw-M" "Relay-R" "Mesh-C"
  exit 0
fi

if ! is_mesh_alias "${mesh_alias}"; then
  json "refused" "$(json_string "mesh_alias_not_public_refused")" "false" \
    "${bundle_id}" "Device-D" "Claw-M" "Relay-R" "Mesh-C"
  exit 0
fi

if [[ "${bundle_id}" != "com.soyeht.app.dev" ]]; then
  json "refused" "$(json_string "bundle_id_not_dev_refused")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

if [[ -z "${SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR:-}" ]]; then
  json "skipped" "$(json_string "evidence_dir_missing")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

evidence_dir="$(normalize_path "${SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR}")"
prepare_private_dir "${evidence_dir}"

if [[ -z "${SOYEHT_IOS_DEVICE_DESTINATION:-}" ]]; then
  json "skipped" "$(json_string "ios_device_destination_missing_explicit_selection_required")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

if [[ -z "${SOYEHT_IOS_DEVICE_ID:-}" ]]; then
  json "skipped" "$(json_string "ios_device_id_missing_explicit_selection_required")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

if [[ -z "${SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID:-}" ]]; then
  json "skipped" "$(json_string "mobile_claw_vpn_device_id_missing")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

if [[ -z "${SOYEHT_MOBILE_CLAW_VPN_CLAW_ID:-}" ]]; then
  json "skipped" "$(json_string "mobile_claw_vpn_claw_id_missing")" "false" \
    "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
  exit 0
fi

summary_path="${evidence_dir}/mobile-claw-vpn-dev-e2e-preflight-summary.json"
python3 - "${summary_path}" "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}" <<'PY'
import json
import os
import sys
import uuid

path, bundle_id, device_alias, claw_alias, relay_alias, mesh_alias = sys.argv[1:]
payload = {
    "status": "ready",
    "reason": None,
    "run_id": str(uuid.uuid4()),
    "bundle_id": bundle_id,
    "device_alias": device_alias,
    "claw_alias": claw_alias,
    "relay_alias": relay_alias,
    "mesh_alias": mesh_alias,
    "evidence_dir_prepared": True,
    "explicit_device_selection_present": True,
    "control_plane_launch_ids_present": True,
    "raw_values_printed": False,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, sort_keys=True)
    f.write("\n")
os.chmod(path, 0o600)
PY

json "ready" "null" "true" \
  "${bundle_id}" "${device_alias}" "${claw_alias}" "${relay_alias}" "${mesh_alias}"
