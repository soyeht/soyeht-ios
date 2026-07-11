#!/bin/bash
# Hermetic mutation matrix for the repo-level iOS PRE-EFFECT crossing guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKER="${ROOT}/scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-owner-present-gate.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

MARKER_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_runtime_activation_v1.json"
ERROR_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
ERROR_VENDOR_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
PIN_REL="scripts/cross-repo-contract.sha"
SEALED_PATHS=(
  "Packages/SoyehtCore/Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/MobileClawVPNDevE2EExecutionTupleV1.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalContextV2DTO.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalV2DTO.swift"
)
SURFACES=(
  "core:Packages/SoyehtCore/Sources/SoyehtCore/API/CrossingProbe.swift"
  "ios_app:TerminalApp/Soyeht/Settings/CrossingProbe.swift"
  "mac_app:TerminalApp/SoyehtMac/CrossingProbe.swift"
  "notification_extension:TerminalApp/HouseCreatedNotificationService/CrossingProbe.swift"
  "live_activity_extension:TerminalApp/SoyehtLiveActivity/CrossingProbe.swift"
)

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

new_repo() {
  local repo="$1"
  git init -q -b main "${repo}"
  git -C "${repo}" config user.name "PRE-EFFECT Gate Test"
  git -C "${repo}" config user.email "pre-effect-gate@example.test"
  : > "${repo}/.keep"
  git -C "${repo}" add .keep
  git -C "${repo}" commit -qm "initial"
}

commit_all() {
  local repo="$1" message="$2"
  git -C "${repo}" add -A
  git -C "${repo}" commit -qm "${message}"
  git -C "${repo}" rev-parse HEAD
}

write_inert_ios() {
  local repo="$1" path
  for path in "${SEALED_PATHS[@]}"; do
    mkdir -p "${repo}/$(dirname "${path}")"
    cp "${ROOT}/${path}" "${repo}/${path}"
  done
}

write_probe() {
  local output="$1" form="$2"
  mkdir -p "$(dirname "${output}")"
  case "${form}" in
    direct)
      printf '%s\n' 'struct MobileClawVPNOwnerPresentProbe {}' > "${output}"
      ;;
    composed_symbol)
      printf '%s\n' \
        'enum MobileClawVPNApprovalTransport {' \
        '    static func send() {}' \
        '}' > "${output}"
      ;;
    composed_path)
      printf '%s\n' \
        'enum MobileClawVPNRouteProbe {' \
        '    static let route = ["owner", "present", "finish"].joined(separator: "-")' \
        '}' > "${output}"
      ;;
  esac
}

write_marker() {
  local repo="$1" digest="$2"
  mkdir -p "${repo}/$(dirname "${MARKER_REL}")"
  cat > "${repo}/${MARKER_REL}" <<EOF
{
  "contract": "soyeht-mobile-claw-vpn-owner-present-runtime-activation-v1",
  "version": 1,
  "error_wire": {
    "theyos_path": "${ERROR_REL}",
    "ios_path": "${ERROR_VENDOR_REL}",
    "sha256": "${digest}"
  }
}
EOF
}

write_pin() {
  local ios="$1" pin="$2"
  mkdir -p "${ios}/$(dirname "${PIN_REL}")"
  printf '%s\n' "${pin}" > "${ios}/${PIN_REL}"
}

expect_pass() {
  local label="$1"
  shift
  if ! "$@" > "${TMP_DIR}/${label}.log" 2>&1; then
    cat "${TMP_DIR}/${label}.log"
    echo "expected pass: ${label}" >&2
    exit 1
  fi
  echo "PASS ${label}"
}

expect_fail() {
  local label="$1" expected="$2"
  shift 2
  if "$@" > "${TMP_DIR}/${label}.log" 2>&1; then
    cat "${TMP_DIR}/${label}.log"
    echo "expected failure: ${label}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" "${TMP_DIR}/${label}.log"; then
    cat "${TMP_DIR}/${label}.log"
    echo "missing failure reason for ${label}: ${expected}" >&2
    exit 1
  fi
  echo "PASS ${label}_refused"
}

INERT_IOS="${TMP_DIR}/inert-ios"
INERT_THEYOS="${TMP_DIR}/inert-theyos"
new_repo "${INERT_IOS}"
new_repo "${INERT_THEYOS}"
write_inert_ios "${INERT_IOS}"
commit_all "${INERT_IOS}" "sealed PRE-EFFECT boundary" >/dev/null
expect_pass inert "${CHECKER}" "${INERT_IOS}" "${INERT_THEYOS}"

UNRELATED_IOS="${TMP_DIR}/unrelated-ios"
UNRELATED_THEYOS="${TMP_DIR}/unrelated-theyos"
git clone -q "${INERT_IOS}" "${UNRELATED_IOS}"
git clone -q "${INERT_THEYOS}" "${UNRELATED_THEYOS}"
git -C "${UNRELATED_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${UNRELATED_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${UNRELATED_IOS}/TerminalApp/Soyeht/Settings"
printf '%s\n' 'struct UnrelatedSettingsProbe {}' \
  > "${UNRELATED_IOS}/TerminalApp/Soyeht/Settings/UnrelatedSettingsProbe.swift"
commit_all "${UNRELATED_IOS}" "unrelated shipping change" >/dev/null
expect_pass unrelated_shipping "${CHECKER}" "${UNRELATED_IOS}" "${UNRELATED_THEYOS}"

SEALED_IOS="${TMP_DIR}/sealed-mutation-ios"
SEALED_THEYOS="${TMP_DIR}/sealed-mutation-theyos"
git clone -q "${INERT_IOS}" "${SEALED_IOS}"
git clone -q "${INERT_THEYOS}" "${SEALED_THEYOS}"
git -C "${SEALED_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SEALED_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '// runtime crossing' >> "${SEALED_IOS}/${SEALED_PATHS[0]}"
commit_all "${SEALED_IOS}" "mutate sealed boundary" >/dev/null
expect_fail sealed_boundary "requires the ODB-verified activation marker" \
  "${CHECKER}" "${SEALED_IOS}" "${SEALED_THEYOS}"

# Every runtime form is injected at the real path of every shipping surface.
for surface_pair in "${SURFACES[@]}"; do
  surface="${surface_pair%%:*}"
  relative_path="${surface_pair#*:}"
  for form in direct composed_symbol composed_path; do
    CASE_IOS="${TMP_DIR}/${surface}-${form}-ios"
    CASE_THEYOS="${TMP_DIR}/${surface}-${form}-theyos"
    git clone -q "${INERT_IOS}" "${CASE_IOS}"
    git clone -q "${INERT_THEYOS}" "${CASE_THEYOS}"
    git -C "${CASE_IOS}" config user.name "PRE-EFFECT Gate Test"
    git -C "${CASE_IOS}" config user.email "pre-effect-gate@example.test"
    write_probe "${CASE_IOS}/${relative_path}" "${form}"
    commit_all "${CASE_IOS}" "${form} crossing in ${surface}" >/dev/null
    expect_fail "${surface}_${form}" "requires the ODB-verified activation marker" \
      "${CHECKER}" "${CASE_IOS}" "${CASE_THEYOS}"
  done
done

MARKER_IOS="${TMP_DIR}/marker-ios"
MARKER_THEYOS="${TMP_DIR}/marker-theyos"
git clone -q "${INERT_IOS}" "${MARKER_IOS}"
git clone -q "${INERT_THEYOS}" "${MARKER_THEYOS}"
git -C "${MARKER_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_IOS}" config user.email "pre-effect-gate@example.test"
git -C "${MARKER_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_THEYOS}" config user.email "pre-effect-gate@example.test"
write_probe "${MARKER_IOS}/${SURFACES[0]#*:}" direct
commit_all "${MARKER_IOS}" "runtime with marker" >/dev/null
write_marker "${MARKER_THEYOS}" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
commit_all "${MARKER_THEYOS}" "marker without error wire" >/dev/null
expect_fail marker_without_error "requires the authoritative error-wire fixture" \
  "${CHECKER}" "${MARKER_IOS}" "${MARKER_THEYOS}"

CLOSED_IOS="${TMP_DIR}/closed-ios"
CLOSED_THEYOS="${TMP_DIR}/closed-theyos"
new_repo "${CLOSED_IOS}"
new_repo "${CLOSED_THEYOS}"
write_inert_ios "${CLOSED_IOS}"
write_probe "${CLOSED_IOS}/${SURFACES[0]#*:}" direct
mkdir -p "${CLOSED_THEYOS}/$(dirname "${ERROR_REL}")"
printf '%s\n' '{"contract":"opaque-error-v1"}' > "${CLOSED_THEYOS}/${ERROR_REL}"
ERROR_SHA="$(sha256_file "${CLOSED_THEYOS}/${ERROR_REL}")"
write_marker "${CLOSED_THEYOS}" "${ERROR_SHA}"
CLOSED_THEYOS_HEAD="$(commit_all "${CLOSED_THEYOS}" "closed error contract")"
mkdir -p "${CLOSED_IOS}/$(dirname "${ERROR_VENDOR_REL}")"
cp "${CLOSED_THEYOS}/${ERROR_REL}" "${CLOSED_IOS}/${ERROR_VENDOR_REL}"
write_pin "${CLOSED_IOS}" "${CLOSED_THEYOS_HEAD}"
commit_all "${CLOSED_IOS}" "closed iOS crossing" >/dev/null
git clone -q --bare "${CLOSED_THEYOS}" "${TMP_DIR}/closed-origin.git"
git -C "${CLOSED_THEYOS}" remote add origin "${TMP_DIR}/closed-origin.git"
expect_pass closed "${CHECKER}" "${CLOSED_IOS}" "${CLOSED_THEYOS}"

VENDOR_IOS="${TMP_DIR}/vendor-drift-ios"
VENDOR_THEYOS="${TMP_DIR}/vendor-drift-theyos"
git clone -q "${CLOSED_IOS}" "${VENDOR_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${VENDOR_THEYOS}"
git -C "${VENDOR_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${VENDOR_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '{"contract":"drift"}' > "${VENDOR_IOS}/${ERROR_VENDOR_REL}"
commit_all "${VENDOR_IOS}" "error vendor drift" >/dev/null
expect_fail vendor_drift "must be byte-identical" \
  "${CHECKER}" "${VENDOR_IOS}" "${VENDOR_THEYOS}"

SYMLINK_IOS="${TMP_DIR}/vendor-symlink-ios"
SYMLINK_THEYOS="${TMP_DIR}/vendor-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${SYMLINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${SYMLINK_THEYOS}"
git -C "${SYMLINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SYMLINK_IOS}" config user.email "pre-effect-gate@example.test"
mv "${SYMLINK_IOS}/${ERROR_VENDOR_REL}" "${SYMLINK_IOS}/error-target.json"
ln -s "../../../error-target.json" "${SYMLINK_IOS}/${ERROR_VENDOR_REL}"
commit_all "${SYMLINK_IOS}" "error vendor symlink" >/dev/null
expect_fail vendor_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${SYMLINK_IOS}" "${SYMLINK_THEYOS}"

MISSING_IOS="${TMP_DIR}/missing-vendor-ios"
MISSING_THEYOS="${TMP_DIR}/missing-vendor-theyos"
git clone -q "${CLOSED_IOS}" "${MISSING_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MISSING_THEYOS}"
git -C "${MISSING_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MISSING_IOS}" config user.email "pre-effect-gate@example.test"
rm "${MISSING_IOS}/${ERROR_VENDOR_REL}"
commit_all "${MISSING_IOS}" "missing error vendor" >/dev/null
expect_fail missing_vendor "requires the iOS error-wire vendor" \
  "${CHECKER}" "${MISSING_IOS}" "${MISSING_THEYOS}"

SOURCE_LINK_IOS="${TMP_DIR}/source-symlink-ios"
SOURCE_LINK_THEYOS="${TMP_DIR}/source-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${SOURCE_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${SOURCE_LINK_THEYOS}"
git -C "${SOURCE_LINK_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SOURCE_LINK_THEYOS}" config user.email "pre-effect-gate@example.test"
mv "${SOURCE_LINK_THEYOS}/${ERROR_REL}" "${SOURCE_LINK_THEYOS}/error-source-target.json"
ln -s "../../../../error-source-target.json" "${SOURCE_LINK_THEYOS}/${ERROR_REL}"
commit_all "${SOURCE_LINK_THEYOS}" "error source symlink" >/dev/null
expect_fail source_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${SOURCE_LINK_IOS}" "${SOURCE_LINK_THEYOS}"

MARKER_LINK_IOS="${TMP_DIR}/marker-symlink-ios"
MARKER_LINK_THEYOS="${TMP_DIR}/marker-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${MARKER_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MARKER_LINK_THEYOS}"
git -C "${MARKER_LINK_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_LINK_THEYOS}" config user.email "pre-effect-gate@example.test"
mv "${MARKER_LINK_THEYOS}/${MARKER_REL}" "${MARKER_LINK_THEYOS}/marker-target.json"
ln -s "../../../../marker-target.json" "${MARKER_LINK_THEYOS}/${MARKER_REL}"
commit_all "${MARKER_LINK_THEYOS}" "activation marker symlink" >/dev/null
expect_fail marker_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${MARKER_LINK_IOS}" "${MARKER_LINK_THEYOS}"

PIN_LINK_IOS="${TMP_DIR}/pin-symlink-ios"
PIN_LINK_THEYOS="${TMP_DIR}/pin-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${PIN_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${PIN_LINK_THEYOS}"
git -C "${PIN_LINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PIN_LINK_IOS}" config user.email "pre-effect-gate@example.test"
mv "${PIN_LINK_IOS}/${PIN_REL}" "${PIN_LINK_IOS}/pin-target.sha"
ln -s "../pin-target.sha" "${PIN_LINK_IOS}/${PIN_REL}"
commit_all "${PIN_LINK_IOS}" "cross-repo pin symlink" >/dev/null
expect_fail pin_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${PIN_LINK_IOS}" "${PIN_LINK_THEYOS}"

PIN_IOS="${TMP_DIR}/unlanded-pin-ios"
PIN_THEYOS="${TMP_DIR}/unlanded-pin-theyos"
git clone -q "${CLOSED_IOS}" "${PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${PIN_THEYOS}"
git -C "${PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PIN_IOS}" config user.email "pre-effect-gate@example.test"
SIDE_TREE="$(git -C "${PIN_THEYOS}" rev-parse HEAD^{tree})"
SIDE_PIN="$(printf '%s\n' 'unlanded error pin' | git -C "${PIN_THEYOS}" commit-tree "${SIDE_TREE}")"
write_pin "${PIN_IOS}" "${SIDE_PIN}"
commit_all "${PIN_IOS}" "unlanded error pin" >/dev/null
expect_fail unlanded_pin "is not landed" "${CHECKER}" "${PIN_IOS}" "${PIN_THEYOS}"

MISSING_PIN_IOS="${TMP_DIR}/pin-before-error-ios"
MISSING_PIN_THEYOS="${TMP_DIR}/pin-before-error-theyos"
git clone -q "${CLOSED_IOS}" "${MISSING_PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MISSING_PIN_THEYOS}"
git -C "${MISSING_PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MISSING_PIN_IOS}" config user.email "pre-effect-gate@example.test"
PRE_ERROR_PIN="$(git -C "${MISSING_PIN_THEYOS}" rev-list --max-parents=0 HEAD)"
write_pin "${MISSING_PIN_IOS}" "${PRE_ERROR_PIN}"
commit_all "${MISSING_PIN_IOS}" "pin predates error wire" >/dev/null
expect_fail pin_without_error "does not contain the owner-present error wire" \
  "${CHECKER}" "${MISSING_PIN_IOS}" "${MISSING_PIN_THEYOS}"

STALE_PIN_IOS="${TMP_DIR}/stale-pin-ios"
STALE_PIN_THEYOS="${TMP_DIR}/stale-pin-theyos"
git clone -q "${CLOSED_IOS}" "${STALE_PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${STALE_PIN_THEYOS}"
git -C "${STALE_PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${STALE_PIN_IOS}" config user.email "pre-effect-gate@example.test"
git -C "${STALE_PIN_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${STALE_PIN_THEYOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '{"contract":"opaque-error-v1","revision":2}' \
  > "${STALE_PIN_THEYOS}/${ERROR_REL}"
STALE_SHA="$(sha256_file "${STALE_PIN_THEYOS}/${ERROR_REL}")"
write_marker "${STALE_PIN_THEYOS}" "${STALE_SHA}"
commit_all "${STALE_PIN_THEYOS}" "source advanced past pin" >/dev/null
cp "${STALE_PIN_THEYOS}/${ERROR_REL}" "${STALE_PIN_IOS}/${ERROR_VENDOR_REL}"
commit_all "${STALE_PIN_IOS}" "vendor follows unpinned source" >/dev/null
expect_fail stale_pin "must be byte-identical" \
  "${CHECKER}" "${STALE_PIN_IOS}" "${STALE_PIN_THEYOS}"

DIGEST_IOS="${TMP_DIR}/wrong-digest-ios"
DIGEST_THEYOS="${TMP_DIR}/wrong-digest-theyos"
git clone -q "${CLOSED_IOS}" "${DIGEST_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${DIGEST_THEYOS}"
git -C "${DIGEST_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${DIGEST_THEYOS}" config user.email "pre-effect-gate@example.test"
write_marker "${DIGEST_THEYOS}" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
commit_all "${DIGEST_THEYOS}" "wrong marker digest" >/dev/null
expect_fail marker_digest "does not match authoritative error-wire bytes" \
  "${CHECKER}" "${DIGEST_IOS}" "${DIGEST_THEYOS}"

echo "iOS owner-present PRE-EFFECT mutation matrix passed."
