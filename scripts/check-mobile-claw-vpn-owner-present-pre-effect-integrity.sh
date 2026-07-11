#!/bin/bash
# Compare protected PRE-EFFECT gate objects without executing code from the PR head.
set -euo pipefail

REPO="${1:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT THEYOS_REPO}"
BASE_COMMIT="${2:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT THEYOS_REPO}"
HEAD_COMMIT="${3:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT THEYOS_REPO}"
THEYOS_REPO="${4:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT THEYOS_REPO}"

PIN_REL="scripts/cross-repo-contract.sha"
C1_PAIRS=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_success_wire_v1.json|admin/contracts/mobile-claw-vpn/v1/owner_present_success_wire_v1.json|537542c2ac1b736cc6704aa55b53d75d6f6a9232"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/OwnerApprovalV2/owner_approval_v2_assertion_fields_v1.json|admin/contracts/owner-approval/v2/owner_approval_v2_assertion_fields_v1.json|2520f4b60bd628b601d2efba0a6ebe0ae8513e5e"
)

PROTECTED_PATHS=(
  ".github/workflows/owner-present-pre-effect-gate.yml"
  ".github/workflows/owner-present-pre-effect-integrity.yml"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
)

for commit in "${BASE_COMMIT}" "${HEAD_COMMIT}"; do
  if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]] \
    || ! git -C "${REPO}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    echo "invalid PRE-EFFECT integrity commit: ${commit}" >&2
    exit 1
  fi
done

tree_entry() {
  git -C "$1" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' \
    "$2" -- ":(literal)$3"
}

require_exact_blob() {
  local repo="$1" commit="$2" path="$3" expected_object="$4" label="$5"
  local entry
  entry="$(tree_entry "${repo}" "${commit}" "${path}")"
  if [[ "${entry}" != "100644 blob ${expected_object}" ]]; then
    echo "::error file=${path}::${label} must be immutable 100644 blob ${expected_object}"
    exit 1
  fi
}

for path in "${PROTECTED_PATHS[@]}"; do
  base_entry="$(git -C "${REPO}" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' \
    "${BASE_COMMIT}" -- ":(literal)${path}")"
  head_entry="$(git -C "${REPO}" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' \
    "${HEAD_COMMIT}" -- ":(literal)${path}")"
  if [[ -z "${base_entry}" ]]; then
    echo "trusted base is missing protected PRE-EFFECT gate: ${path}" >&2
    exit 1
  fi
  if [[ "${head_entry}" != "${base_entry}" ]]; then
    echo "::error file=${path}::protected PRE-EFFECT gate changed before activation"
    exit 1
  fi
done

THEYOS_HEAD="$(git -C "${THEYOS_REPO}" rev-parse HEAD)"
if [[ ! "${THEYOS_HEAD}" =~ ^[0-9a-f]{40}$ ]] \
  || ! git -C "${THEYOS_REPO}" cat-file -e "${THEYOS_HEAD}^{commit}" 2>/dev/null; then
  echo "invalid theyos authority HEAD: ${THEYOS_HEAD}" >&2
  exit 1
fi

PIN_ENTRY="$(tree_entry "${REPO}" "${HEAD_COMMIT}" "${PIN_REL}")"
read -r pin_mode pin_type pin_object <<< "${PIN_ENTRY}"
if [[ "${pin_mode}" != "100644" || "${pin_type}" != "blob" \
  || ! "${pin_object}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error file=${PIN_REL}::C1 pin must be an ordinary 100644 Git blob"
  exit 1
fi
PIN="$(git -C "${REPO}" cat-file blob "${pin_object}")"
if [[ "$(git -C "${REPO}" cat-file -s "${pin_object}")" != "41" \
  || ! "${PIN}" =~ ^[0-9a-f]{40}$ \
  || "$(printf '%s\n' "${PIN}" | git hash-object --stdin)" != "${pin_object}" ]]; then
  echo "::error file=${PIN_REL}::C1 pin must contain exactly one lowercase 40-hex line"
  exit 1
fi
if ! git -C "${THEYOS_REPO}" cat-file -e "${PIN}^{commit}" 2>/dev/null \
  || ! git -C "${THEYOS_REPO}" merge-base --is-ancestor "${PIN}" "${THEYOS_HEAD}"; then
  echo "::error file=${PIN_REL}::C1 pin must be one landed theyos main commit"
  exit 1
fi

for pair in "${C1_PAIRS[@]}"; do
  IFS='|' read -r vendor_path source_path expected_object <<< "${pair}"
  require_exact_blob \
    "${REPO}" "${HEAD_COMMIT}" "${vendor_path}" "${expected_object}" \
    "iOS C1 vendor"
  require_exact_blob \
    "${THEYOS_REPO}" "${PIN}" "${source_path}" "${expected_object}" \
    "C1 source at the landed pin"
  require_exact_blob \
    "${THEYOS_REPO}" "${THEYOS_HEAD}" "${source_path}" "${expected_object}" \
    "C1 source on theyos main"
done

echo "Protected owner-present PRE-EFFECT gate and C1 provenance are base-owned and closed."
