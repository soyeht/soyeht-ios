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
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
)

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
  local label="$1"
  shift
  if "$@" > "${TMP_DIR}/${label}.log" 2>&1; then
    cat "${TMP_DIR}/${label}.log"
    echo "expected failure: ${label}" >&2
    exit 1
  fi
  if ! grep -Fq "protected PRE-EFFECT gate changed" "${TMP_DIR}/${label}.log"; then
    cat "${TMP_DIR}/${label}.log"
    echo "missing protected-gate failure reason: ${label}" >&2
    exit 1
  fi
  echo "PASS ${label}_refused"
}

BASE_REPO="${TMP_DIR}/base"
git init -q -b main "${BASE_REPO}"
configure_repo "${BASE_REPO}"
for path in "${PROTECTED_PATHS[@]}"; do
  mkdir -p "${BASE_REPO}/$(dirname "${path}")"
  cp -p "${ROOT}/${path}" "${BASE_REPO}/${path}"
done
BASE_COMMIT="$(commit_all "${BASE_REPO}" "trusted PRE-EFFECT gate")"
expect_pass unchanged "${CHECKER}" "${BASE_REPO}" "${BASE_COMMIT}" "${BASE_COMMIT}"

UNRELATED_REPO="${TMP_DIR}/unrelated"
git clone -q "${BASE_REPO}" "${UNRELATED_REPO}"
configure_repo "${UNRELATED_REPO}"
mkdir -p "${UNRELATED_REPO}/Sources"
printf '%s\n' 'struct UnrelatedChange {}' > "${UNRELATED_REPO}/Sources/Unrelated.swift"
UNRELATED_HEAD="$(commit_all "${UNRELATED_REPO}" "unrelated change")"
expect_pass unrelated "${CHECKER}" "${UNRELATED_REPO}" "${BASE_COMMIT}" "${UNRELATED_HEAD}"

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
  expect_fail "${label}" "${CHECKER}" "${CASE_REPO}" "${BASE_COMMIT}" "${CASE_HEAD}"
done

echo "Owner-present PRE-EFFECT integrity mutation matrix passed."
