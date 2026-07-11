#!/bin/bash
# Hermetic mutation matrix for the base-owned PRE-EFFECT integrity gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKER="${ROOT}/scripts/check-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-owner-present-integrity.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

PROTECTED_PATHS=(
  ".github/workflows/owner-present-pre-effect-gate.yml"
  ".github/workflows/owner-present-pre-effect-integrity.yml"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  "scripts/mobile-claw-vpn-owner-present-automation-baseline.tsv"
  "scripts/mobile-claw-vpn-owner-present-binary-baseline.tsv"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
)
C1_PAIRS=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_success_wire_v1.json|admin/contracts/mobile-claw-vpn/v1/owner_present_success_wire_v1.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/OwnerApprovalV2/owner_approval_v2_assertion_fields_v1.json|admin/contracts/owner-approval/v2/owner_approval_v2_assertion_fields_v1.json"
)
HEAD_OWNED_CONTRACT_GUARD_PATHS=(
  ".github/workflows/contract-fixture-sync.yml"
  "scripts/check-cross-repo-fixtures.sh"
  "scripts/test-cross-repo-fixture-guard.sh"
)
PIN_REL="scripts/cross-repo-contract.sha"
INTEGRITY_WORKFLOW_REL=".github/workflows/owner-present-pre-effect-integrity.yml"

configure_repo() {
  git -C "$1" config user.name "PRE-EFFECT Integrity Test"
  git -C "$1" config user.email "pre-effect-integrity@example.test"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
  git -C "$1" rev-parse HEAD
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

# A path filter on an integrity authority can be skipped when GitHub truncates
# changed-path evaluation. This workflow must be created for every PR to main.
if grep -Eq '^[[:space:]]+paths(-ignore)?:' \
  "${ROOT}/${INTEGRITY_WORKFLOW_REL}"; then
  echo "integrity pull_request_target must not use path filters" >&2
  exit 1
fi
echo "PASS integrity_workflow_has_no_path_filter"

AUTH_REPO="${TMP_DIR}/theyos"
git init -q -b main "${AUTH_REPO}"
configure_repo "${AUTH_REPO}"
for pair in "${C1_PAIRS[@]}"; do
  vendor_path="${pair%%|*}"
  source_path="${pair#*|}"
  mkdir -p "${AUTH_REPO}/$(dirname "${source_path}")"
  cp "${ROOT}/${vendor_path}" "${AUTH_REPO}/${source_path}"
done
PIN_COMMIT="$(commit_all "${AUTH_REPO}" "land immutable C1 sources")"
mkdir -p "${AUTH_REPO}/admin/contracts"
printf '%s\n' 'authority main remains ahead of the landed pin' \
  > "${AUTH_REPO}/admin/contracts/README"
commit_all "${AUTH_REPO}" "advance authority main" >/dev/null

BASE_REPO="${TMP_DIR}/base"
git init -q -b main "${BASE_REPO}"
configure_repo "${BASE_REPO}"
for path in "${PROTECTED_PATHS[@]}"; do
  mkdir -p "${BASE_REPO}/$(dirname "${path}")"
  cp -p "${ROOT}/${path}" "${BASE_REPO}/${path}"
done
for path in "${HEAD_OWNED_CONTRACT_GUARD_PATHS[@]}"; do
  mkdir -p "${BASE_REPO}/$(dirname "${path}")"
  cp -p "${ROOT}/${path}" "${BASE_REPO}/${path}"
done
for pair in "${C1_PAIRS[@]}"; do
  vendor_path="${pair%%|*}"
  mkdir -p "${BASE_REPO}/$(dirname "${vendor_path}")"
  cp "${ROOT}/${vendor_path}" "${BASE_REPO}/${vendor_path}"
done
mkdir -p "${BASE_REPO}/$(dirname "${PIN_REL}")"
printf '%s\n' "${PIN_COMMIT}" > "${BASE_REPO}/${PIN_REL}"
BASE_COMMIT="$(commit_all "${BASE_REPO}" "trusted PRE-EFFECT gate")"
expect_pass unchanged \
  "${CHECKER}" "${BASE_REPO}" "${BASE_COMMIT}" "${BASE_COMMIT}" "${AUTH_REPO}"

UNRELATED_REPO="${TMP_DIR}/unrelated"
git clone -q "${BASE_REPO}" "${UNRELATED_REPO}"
configure_repo "${UNRELATED_REPO}"
mkdir -p "${UNRELATED_REPO}/Sources"
printf '%s\n' 'struct UnrelatedChange {}' > "${UNRELATED_REPO}/Sources/Unrelated.swift"
UNRELATED_HEAD="$(commit_all "${UNRELATED_REPO}" "unrelated change")"
expect_pass unrelated \
  "${CHECKER}" "${UNRELATED_REPO}" "${BASE_COMMIT}" "${UNRELATED_HEAD}" "${AUTH_REPO}"

LARGE_DIFF_REPO="${TMP_DIR}/large-diff-protected-tamper"
git clone -q "${BASE_REPO}" "${LARGE_DIFF_REPO}"
configure_repo "${LARGE_DIFF_REPO}"
mkdir -p "${LARGE_DIFF_REPO}/A-volume"
for index in $(seq -w 0 300); do
  printf '%s\n' "neutral file ${index}" \
    > "${LARGE_DIFF_REPO}/A-volume/${index}.txt"
done
printf '%s\n' '#!/bin/bash' 'runtime_detected=0' 'exit 0' \
  > "${LARGE_DIFF_REPO}/scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
chmod +x \
  "${LARGE_DIFF_REPO}/scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
LARGE_DIFF_HEAD="$(commit_all \
  "${LARGE_DIFF_REPO}" "protected tamper behind more than 300 paths")"
expect_fail large_diff_protected_tamper \
  "protected PRE-EFFECT gate changed" \
  "${CHECKER}" "${LARGE_DIFF_REPO}" "${BASE_COMMIT}" \
  "${LARGE_DIFF_HEAD}" "${AUTH_REPO}"

for path in "${PROTECTED_PATHS[@]}"; do
  label="$(printf '%s' "${path}" | tr '/.' '__')"
  CASE_REPO="${TMP_DIR}/${label}"
  git clone -q "${BASE_REPO}" "${CASE_REPO}"
  configure_repo "${CASE_REPO}"
  if [[ "${path}" == "scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh" ]]; then
    printf '%s\n' '#!/bin/bash' 'runtime_detected=0' 'exit 0' > "${CASE_REPO}/${path}"
    chmod +x "${CASE_REPO}/${path}"
  else
    printf '%s\n' '# integrity mutation' >> "${CASE_REPO}/${path}"
  fi
  CASE_HEAD="$(commit_all "${CASE_REPO}" "mutate ${path}")"
  expect_fail "${label}" "protected PRE-EFFECT gate changed" \
    "${CHECKER}" "${CASE_REPO}" "${BASE_COMMIT}" "${CASE_HEAD}" "${AUTH_REPO}"
done

EVOLVING_REPO="${TMP_DIR}/head-owned-guard-evolution"
git clone -q "${BASE_REPO}" "${EVOLVING_REPO}"
configure_repo "${EVOLVING_REPO}"
for path in "${HEAD_OWNED_CONTRACT_GUARD_PATHS[@]}"; do
  printf '%s\n' '#!/bin/bash' 'exit 0' > "${EVOLVING_REPO}/${path}"
  [[ "${path}" == *.sh ]] && chmod +x "${EVOLVING_REPO}/${path}"
done
EVOLVING_HEAD="$(commit_all "${EVOLVING_REPO}" "head-owned guards become no-ops")"
expect_pass head_owned_guards_are_not_authority \
  "${CHECKER}" "${EVOLVING_REPO}" "${BASE_COMMIT}" "${EVOLVING_HEAD}" "${AUTH_REPO}"

for pair in "${C1_PAIRS[@]}"; do
  vendor_path="${pair%%|*}"
  label="$(basename "${vendor_path}" .json)"
  DRIFT_REPO="${TMP_DIR}/${label}-vendor-drift"
  git clone -q "${BASE_REPO}" "${DRIFT_REPO}"
  configure_repo "${DRIFT_REPO}"
  printf '%s\n' 'drift' >> "${DRIFT_REPO}/${vendor_path}"
  DRIFT_HEAD="$(commit_all "${DRIFT_REPO}" "drift ${label} vendor")"
  expect_fail "${label}_vendor_drift" "iOS C1 vendor must be immutable" \
    "${CHECKER}" "${DRIFT_REPO}" "${BASE_COMMIT}" "${DRIFT_HEAD}" "${AUTH_REPO}"
done

VENDOR_LINK_REPO="${TMP_DIR}/vendor-symlink"
git clone -q "${BASE_REPO}" "${VENDOR_LINK_REPO}"
configure_repo "${VENDOR_LINK_REPO}"
VENDOR_LINK_PATH="${C1_PAIRS[0]%%|*}"
mv "${VENDOR_LINK_REPO}/${VENDOR_LINK_PATH}" "${VENDOR_LINK_REPO}/vendor-target.json"
ln -s ../../../../../../vendor-target.json "${VENDOR_LINK_REPO}/${VENDOR_LINK_PATH}"
VENDOR_LINK_HEAD="$(commit_all "${VENDOR_LINK_REPO}" "vendor symlink")"
expect_fail vendor_symlink "iOS C1 vendor must be immutable" \
  "${CHECKER}" "${VENDOR_LINK_REPO}" "${BASE_COMMIT}" "${VENDOR_LINK_HEAD}" "${AUTH_REPO}"

VENDOR_GITLINK_REPO="${TMP_DIR}/vendor-gitlink"
git clone -q "${BASE_REPO}" "${VENDOR_GITLINK_REPO}"
configure_repo "${VENDOR_GITLINK_REPO}"
VENDOR_GITLINK_PATH="${C1_PAIRS[1]%%|*}"
rm "${VENDOR_GITLINK_REPO}/${VENDOR_GITLINK_PATH}"
git -C "${VENDOR_GITLINK_REPO}" update-index --force-remove "${VENDOR_GITLINK_PATH}"
GITLINK_TARGET="$(git -C "${VENDOR_GITLINK_REPO}" rev-parse HEAD)"
git -C "${VENDOR_GITLINK_REPO}" update-index --add \
  --cacheinfo "160000,${GITLINK_TARGET},${VENDOR_GITLINK_PATH}"
git -C "${VENDOR_GITLINK_REPO}" commit -qm "vendor gitlink"
VENDOR_GITLINK_HEAD="$(git -C "${VENDOR_GITLINK_REPO}" rev-parse HEAD)"
expect_fail vendor_gitlink "iOS C1 vendor must be immutable" \
  "${CHECKER}" "${VENDOR_GITLINK_REPO}" "${BASE_COMMIT}" \
  "${VENDOR_GITLINK_HEAD}" "${AUTH_REPO}"

PIN_LINK_REPO="${TMP_DIR}/pin-symlink"
git clone -q "${BASE_REPO}" "${PIN_LINK_REPO}"
configure_repo "${PIN_LINK_REPO}"
mv "${PIN_LINK_REPO}/${PIN_REL}" "${PIN_LINK_REPO}/pin-target"
ln -s ../pin-target "${PIN_LINK_REPO}/${PIN_REL}"
PIN_LINK_HEAD="$(commit_all "${PIN_LINK_REPO}" "pin symlink")"
expect_fail pin_symlink "C1 pin must be an ordinary 100644 Git blob" \
  "${CHECKER}" "${PIN_LINK_REPO}" "${BASE_COMMIT}" "${PIN_LINK_HEAD}" "${AUTH_REPO}"

LARGE_PIN_REPO="${TMP_DIR}/large-pin"
git clone -q "${BASE_REPO}" "${LARGE_PIN_REPO}"
configure_repo "${LARGE_PIN_REPO}"
printf '%129s' '' | tr ' ' a > "${LARGE_PIN_REPO}/${PIN_REL}"
LARGE_PIN_HEAD="$(commit_all "${LARGE_PIN_REPO}" "oversized pin blob")"
expect_fail oversized_pin "C1 pin must contain exactly one lowercase 40-hex line" \
  "${CHECKER}" "${LARGE_PIN_REPO}" "${BASE_COMMIT}" "${LARGE_PIN_HEAD}" "${AUTH_REPO}"

NUL_PIN_REPO="${TMP_DIR}/nul-pin"
git clone -q "${BASE_REPO}" "${NUL_PIN_REPO}"
configure_repo "${NUL_PIN_REPO}"
printf '%40s' '' | tr ' ' a > "${NUL_PIN_REPO}/${PIN_REL}"
printf '\000' >> "${NUL_PIN_REPO}/${PIN_REL}"
NUL_PIN_HEAD="$(commit_all "${NUL_PIN_REPO}" "NUL-terminated pin")"
expect_fail nul_pin "C1 pin must contain exactly one lowercase 40-hex line" \
  "${CHECKER}" "${NUL_PIN_REPO}" "${BASE_COMMIT}" "${NUL_PIN_HEAD}" "${AUTH_REPO}"

UNLANDED_PIN_REPO="${TMP_DIR}/unlanded-pin"
git clone -q "${BASE_REPO}" "${UNLANDED_PIN_REPO}"
configure_repo "${UNLANDED_PIN_REPO}"
AUTH_TREE="$(git -C "${AUTH_REPO}" rev-parse HEAD^{tree})"
UNLANDED_PIN="$(printf '%s\n' 'unlanded C1 pin' | git -C "${AUTH_REPO}" commit-tree "${AUTH_TREE}")"
printf '%s\n' "${UNLANDED_PIN}" > "${UNLANDED_PIN_REPO}/${PIN_REL}"
UNLANDED_HEAD="$(commit_all "${UNLANDED_PIN_REPO}" "unlanded pin")"
expect_fail unlanded_pin "C1 pin must be one landed theyos main commit" \
  "${CHECKER}" "${UNLANDED_PIN_REPO}" "${BASE_COMMIT}" "${UNLANDED_HEAD}" "${AUTH_REPO}"

MAIN_DRIFT_AUTH="${TMP_DIR}/main-source-drift-authority"
git clone -q "${AUTH_REPO}" "${MAIN_DRIFT_AUTH}"
configure_repo "${MAIN_DRIFT_AUTH}"
MAIN_DRIFT_SOURCE="${C1_PAIRS[0]#*|}"
printf '%s\n' 'main-only source drift' >> "${MAIN_DRIFT_AUTH}/${MAIN_DRIFT_SOURCE}"
commit_all "${MAIN_DRIFT_AUTH}" "drift immutable source on main" >/dev/null
expect_fail source_main_drift "C1 source on theyos main must be immutable" \
  "${CHECKER}" "${BASE_REPO}" "${BASE_COMMIT}" "${BASE_COMMIT}" "${MAIN_DRIFT_AUTH}"

PIN_DRIFT_AUTH="${TMP_DIR}/pin-source-drift-authority"
git clone -q "${AUTH_REPO}" "${PIN_DRIFT_AUTH}"
configure_repo "${PIN_DRIFT_AUTH}"
git -C "${PIN_DRIFT_AUTH}" checkout -q -B main "${PIN_COMMIT}"
PIN_DRIFT_SOURCE="${C1_PAIRS[1]#*|}"
printf '%s\n' 'pin-only source drift' >> "${PIN_DRIFT_AUTH}/${PIN_DRIFT_SOURCE}"
BAD_SOURCE_PIN="$(commit_all "${PIN_DRIFT_AUTH}" "drift source at candidate pin")"
PIN_DRIFT_VENDOR="${C1_PAIRS[1]%%|*}"
cp "${ROOT}/${PIN_DRIFT_VENDOR}" "${PIN_DRIFT_AUTH}/${PIN_DRIFT_SOURCE}"
commit_all "${PIN_DRIFT_AUTH}" "restore source after candidate pin" >/dev/null
PIN_DRIFT_REPO="${TMP_DIR}/pin-source-drift-ios"
git clone -q "${BASE_REPO}" "${PIN_DRIFT_REPO}"
configure_repo "${PIN_DRIFT_REPO}"
printf '%s\n' "${BAD_SOURCE_PIN}" > "${PIN_DRIFT_REPO}/${PIN_REL}"
PIN_DRIFT_HEAD="$(commit_all "${PIN_DRIFT_REPO}" "point to source-drifted landed pin")"
expect_fail source_pin_drift "C1 source at the landed pin must be immutable" \
  "${CHECKER}" "${PIN_DRIFT_REPO}" "${BASE_COMMIT}" "${PIN_DRIFT_HEAD}" \
  "${PIN_DRIFT_AUTH}"

COORD_AUTH="${TMP_DIR}/coordinated-authority-drift"
git clone -q "${AUTH_REPO}" "${COORD_AUTH}"
configure_repo "${COORD_AUTH}"
COORD_REPO="${TMP_DIR}/coordinated-head-drift"
git clone -q "${BASE_REPO}" "${COORD_REPO}"
configure_repo "${COORD_REPO}"
for pair in "${C1_PAIRS[@]}"; do
  vendor_path="${pair%%|*}"
  source_path="${pair#*|}"
  printf '%s\n' 'coordinated drift' >> "${COORD_AUTH}/${source_path}"
  cp "${COORD_AUTH}/${source_path}" "${COORD_REPO}/${vendor_path}"
done
COORD_PIN="$(commit_all "${COORD_AUTH}" "coordinated authority drift")"
printf '%s\n' "${COORD_PIN}" > "${COORD_REPO}/${PIN_REL}"
for path in "${HEAD_OWNED_CONTRACT_GUARD_PATHS[@]}"; do
  printf '%s\n' '#!/bin/bash' 'exit 0' > "${COORD_REPO}/${path}"
  [[ "${path}" == *.sh ]] && chmod +x "${COORD_REPO}/${path}"
done
COORD_HEAD="$(commit_all "${COORD_REPO}" "no-op guards plus coordinated C1 drift")"
expect_fail coordinated_guard_vendor_pin_drift "iOS C1 vendor must be immutable" \
  "${CHECKER}" "${COORD_REPO}" "${BASE_COMMIT}" "${COORD_HEAD}" "${COORD_AUTH}"

echo "Owner-present PRE-EFFECT integrity mutation matrix passed."
