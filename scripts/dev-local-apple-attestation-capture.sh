#!/usr/bin/env bash
set -euo pipefail

json() {
  printf '{"status":"%s","reason":"%s"}\n' "$1" "$2"
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

if [[ "${SOYEHT_RUN_LOCAL_APPLE_ATTESTATION_CAPTURE:-}" != "1" ]]; then
  json "skipped" "SOYEHT_RUN_LOCAL_APPLE_ATTESTATION_CAPTURE_not_set"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"

if [[ -z "${SOYEHT_DEV_APP_BUNDLE:-}" ]]; then
  json "skipped" "SOYEHT_DEV_APP_BUNDLE_not_set"
  exit 0
fi

if [[ -z "${SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE:-}" ]]; then
  json "refused" "fixture_path_missing"
  exit 0
fi

app_bundle="${SOYEHT_DEV_APP_BUNDLE%/}"
if [[ "${app_bundle}" == "/Applications/Soyeht.app" ]]; then
  json "refused" "shipping_app_bundle_refused"
  exit 0
fi

if [[ ! -d "${app_bundle}" ]]; then
  json "skipped" "dev_app_bundle_missing"
  exit 0
fi

info_plist="${app_bundle}/Contents/Info.plist"
if [[ ! -f "${info_plist}" ]]; then
  json "skipped" "info_plist_missing"
  exit 0
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)"
if [[ "${bundle_id}" != "com.soyeht.mac.dev" ]]; then
  json "refused" "bundle_identifier_not_dev"
  exit 0
fi

set +e
codesign_output="$(codesign -d --requirements :- "${app_bundle}" 2>&1)"
codesign_status=$?
set -e

if [[ "${codesign_status}" != "0" ]]; then
  json "refused" "codesign_requirement_unavailable"
  exit 0
fi

designated_requirement="$(printf '%s\n' "${codesign_output}" | awk '/^designated =>/ { print; exit }')"
if [[ -z "${designated_requirement}" ]]; then
  json "refused" "codesign_requirement_unavailable"
  exit 0
fi

if [[ "${designated_requirement}" != *'identifier "com.soyeht.mac.dev"'* ]]; then
  json "refused" "codesign_identifier_not_dev"
  exit 0
fi
if [[ "${designated_requirement}" != *'W7677A5BK2'* ]]; then
  json "refused" "codesign_team_not_soyeht"
  exit 0
fi

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null || true)"
if [[ -z "${executable_name}" ]]; then
  json "skipped" "bundle_executable_missing"
  exit 0
fi

executable_path="${app_bundle}/Contents/MacOS/${executable_name}"
if [[ ! -x "${executable_path}" ]]; then
  json "skipped" "bundle_executable_not_runnable"
  exit 0
fi

fixture_path="$(normalize_path "${SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE}")"
if is_inside_repo "${fixture_path}"; then
  json "refused" "fixture_path_inside_repo_refused"
  exit 0
fi

cleanup_result_file=0
if [[ -n "${SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE_RESULT:-}" ]]; then
  result_file="$(normalize_path "${SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE_RESULT}")"
  if is_inside_repo "${result_file}"; then
    json "refused" "result_path_inside_repo_refused"
    exit 0
  fi
else
  result_file="$(mktemp "${TMPDIR:-/tmp}/soyeht-local-attestation-capture.XXXXXX.json")"
  cleanup_result_file=1
fi

if [[ "${result_file}" == "${fixture_path}" ]]; then
  json "refused" "result_path_matches_fixture_path"
  exit 0
fi

cleanup() {
  if [[ "${cleanup_result_file}" == "1" ]]; then
    rm -f "${result_file}"
  fi
}
trap cleanup EXIT

umask 077

set +e
SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE=1 \
SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE="${fixture_path}" \
SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE_RESULT="${result_file}" \
"${executable_path}"
status=$?
set -e

if [[ -s "${result_file}" ]]; then
  cat "${result_file}"
else
  json "failed" "result_missing"
fi

exit "${status}"
