#!/bin/bash
# Read-only guard: verifies the vendored cross-repo contract fixtures in this repo
# byte-match the theyos source of truth. This is the iOS-side, content-level
# counterpart to theyos's contracts-cross-repo-sync.yml — theyos guards drift on
# ITS PRs; this guards drift on OURS, closing the asymmetry where the iOS side
# previously only required a linked companion PR (cross-repo-dep-check.yml) but
# never compared the bytes.
#
# Source resolution (in order):
#   1. THEYOS_DIR=<path>  — diff against a local theyos checkout (dev / local CI).
#   2. otherwise          — fetch from github raw at the SHA in
#                           scripts/cross-repo-contract.sha (hosted CI).
#
# A source file absent at the resolved point is reported as a skip (not a failure)
# for that file, matching theyos's own "skip until it lands" behavior, so a
# contract that has not yet merged to the pinned ref does not spuriously fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PIN_FILE="${SCRIPT_DIR}/cross-repo-contract.sha"
THEYOS_SHA="$(grep -vE '^[[:space:]]*#' "${PIN_FILE}" | tr -d '[:space:]')"

# vendored-iOS-relative-path : theyos-relative-path
PAIRS=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json:admin/contracts/claw-store/v1/contract.json"
  "docs/contracts/claw-store-household-v1.json:docs/contracts/claw-store-household-v1.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/GuestImageFailureCode/guest_image_failure_codes.json:admin/rust/core-rs/tests/fixtures/guest_image_failure_codes.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/BootstrapErrorCode/bootstrap_error_codes.json:admin/rust/household-rs/tests/fixtures/bootstrap_error_codes.json"
)

# Write the theyos source for $1 into the file $2.
# Echoes one of: present | absent | error
materialize_source() {
  local path="$1" dest="$2"
  if [[ -n "${THEYOS_DIR:-}" ]]; then
    if [[ -f "${THEYOS_DIR}/${path}" ]]; then
      cp "${THEYOS_DIR}/${path}" "${dest}"
      echo present
    else
      echo absent
    fi
    return 0
  fi
  local url="https://raw.githubusercontent.com/soyeht/theyos/${THEYOS_SHA}/${path}"
  local status
  status="$(curl -fsSL -o "${dest}" -w '%{http_code}' "${url}" 2>/dev/null || true)"
  case "${status}" in
    200) echo present ;;
    404) echo absent ;;
    *) echo error ;;
  esac
}

if [[ -n "${THEYOS_DIR:-}" ]]; then
  echo "Checking iOS contract fixtures against local theyos at: ${THEYOS_DIR}"
else
  echo "Checking iOS contract fixtures against theyos@${THEYOS_SHA}"
fi

DRIFT=0
for pair in "${PAIRS[@]}"; do
  ios="${pair%%:*}"
  src="${pair##*:}"
  ios_abs="${REPO_ROOT}/${ios}"

  if [[ ! -f "${ios_abs}" ]]; then
    echo "::error::vendored fixture missing in this repo: ${ios}"
    DRIFT=1
    continue
  fi

  src_tmp="$(mktemp)"
  case "$(materialize_source "${src}" "${src_tmp}")" in
    absent)
      echo "↷ skip ${ios}: theyos source ${src} not present at the pinned point yet"
      ;;
    error)
      echo "::error::could not read theyos source ${src} (network error)"
      DRIFT=1
      ;;
    present)
      if diff -u "${src_tmp}" "${ios_abs}" >/dev/null; then
        echo "✓ ${ios} matches theyos:${src}"
      else
        echo "::error::contract drift: ${ios} differs from theyos:${src}"
        echo "  re-sync with: THEYOS_DIR=<theyos> scripts/sync-cross-repo-fixtures.sh"
        diff -u "${src_tmp}" "${ios_abs}" || true
        DRIFT=1
      fi
      ;;
  esac
  rm -f "${src_tmp}"
done

if [[ "${DRIFT}" -ne 0 ]]; then
  echo "Cross-repo contract drift detected."
  exit 1
fi
echo "All vendored contract fixtures are in sync."
