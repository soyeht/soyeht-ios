#!/bin/bash
# Compare protected PRE-EFFECT gate objects without executing code from the PR head.
set -euo pipefail

REPO="${1:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT}"
BASE_COMMIT="${2:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT}"
HEAD_COMMIT="${3:?usage: $0 REPO BASE_COMMIT HEAD_COMMIT}"

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

echo "Protected owner-present PRE-EFFECT gate is byte-identical to the trusted base."
