#!/usr/bin/env bash
set -euo pipefail

if [[ "${SOYEHT_RUN_DEV_ENGINE_SMOKE:-}" != "1" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"SOYEHT_RUN_DEV_ENGINE_SMOKE_not_set"}'
  exit 0
fi

if [[ -z "${SOYEHT_DEV_APP_BUNDLE:-}" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"SOYEHT_DEV_APP_BUNDLE_not_set"}'
  exit 0
fi

app_bundle="${SOYEHT_DEV_APP_BUNDLE}"
if [[ "${app_bundle}" == "/Applications/Soyeht.app" ]]; then
  printf '%s\n' '{"status":"refused","reason":"shipping_app_bundle_refused"}'
  exit 0
fi

if [[ ! -d "${app_bundle}" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"dev_app_bundle_missing"}'
  exit 0
fi

info_plist="${app_bundle}/Contents/Info.plist"
if [[ ! -f "${info_plist}" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"info_plist_missing"}'
  exit 0
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)"
if [[ "${bundle_id}" != "com.soyeht.mac.dev" ]]; then
  printf '%s\n' '{"status":"refused","reason":"bundle_identifier_not_dev"}'
  exit 0
fi

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null || true)"
if [[ -z "${executable_name}" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"bundle_executable_missing"}'
  exit 0
fi

executable_path="${app_bundle}/Contents/MacOS/${executable_name}"
if [[ ! -x "${executable_path}" ]]; then
  printf '%s\n' '{"status":"skipped","reason":"bundle_executable_not_runnable"}'
  exit 0
fi

result_file="${TMPDIR:-/tmp}/soyeht-dev-engine-smoke.$$.json"
cleanup() {
  rm -f "${result_file}"
}
trap cleanup EXIT

set +e
SOYEHT_DEV_ENGINE_SMOKE=1 \
SOYEHT_DEV_ENGINE_SMOKE_RESULT="${result_file}" \
SOYEHT_DEV_ENGINE_SMOKE_STRICT="${SOYEHT_DEV_ENGINE_SMOKE_STRICT:-}" \
"${executable_path}"
status=$?
set -e

if [[ -s "${result_file}" ]]; then
  cat "${result_file}"
else
  printf '%s\n' '{"status":"failed","reason":"result_missing"}'
fi

exit "${status}"
