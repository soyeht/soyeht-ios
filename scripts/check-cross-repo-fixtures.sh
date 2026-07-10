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
# Required Claw Store sources must be present at the resolved point. Optional
# legacy fixture sources can still skip while a source has not landed yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

materialize_tracked_ios_file() {
  local relative_path="$1" destination="$2"
  local entry mode object stage ignored absolute_path

  entry="$(git -C "${REPO_ROOT}" ls-files --stage -- "${relative_path}")"
  if [[ -z "${entry}" || "${entry}" == *$'\n'* ]]; then
    echo "::error::vendored contract must have exactly one tracked Git entry: ${relative_path}"
    return 1
  fi
  read -r mode object stage ignored <<< "${entry}"
  if [[ "${mode}" != "100644" || "${stage}" != "0" ]]; then
    echo "::error::vendored contract must be an ordinary 100644 Git blob: ${relative_path}"
    return 1
  fi

  absolute_path="${REPO_ROOT}/${relative_path}"
  if [[ -L "${absolute_path}" || ! -f "${absolute_path}" ]]; then
    echo "::error::vendored contract checkout must be a regular file, not a symlink: ${relative_path}"
    return 1
  fi
  git -C "${REPO_ROOT}" cat-file blob "${object}" > "${destination}"
  if ! cmp -s "${destination}" "${absolute_path}"; then
    echo "::error::vendored contract working copy differs from its tracked blob: ${relative_path}"
    return 1
  fi
}

PIN_REL="scripts/cross-repo-contract.sha"
PIN_FILE="${REPO_ROOT}/${PIN_REL}"
PIN_BLOB="${TMP_DIR}/cross-repo-contract.sha"
materialize_tracked_ios_file "${PIN_REL}" "${PIN_BLOB}"
THEYOS_SHA="$(grep -vE '^[[:space:]]*#' "${PIN_BLOB}" | tr -d '[:space:]')"
if [[ ! "${THEYOS_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::${PIN_FILE} must contain exactly one lowercase 40-hex theyos commit"
  exit 1
fi

if [[ -n "${THEYOS_DIR:-}" && "${SOYEHT_REQUIRE_LOCAL_PIN:-0}" == "1" ]]; then
  local_head="$(git -C "${THEYOS_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ "${local_head}" != "${THEYOS_SHA}" ]]; then
    echo "::error::local theyos HEAD ${local_head:-missing} does not match pin ${THEYOS_SHA}"
    exit 1
  fi
fi

# requirement : vendored-iOS-relative-path : theyos-relative-path
PAIRS=(
  "required:Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json:admin/contracts/claw-store/v1/contract.json"
  "required:Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/api_shapes.json:admin/contracts/mobile-claw-vpn/v1/api_shapes.json"
  "required:Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json:admin/contracts/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json"
  "required:docs/contracts/claw-store-household-v1.json:docs/contracts/claw-store-household-v1.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/GuestImageFailureCode/guest_image_failure_codes.json:admin/rust/core-rs/tests/fixtures/guest_image_failure_codes.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/BootstrapErrorCode/bootstrap_error_codes.json:admin/rust/household-rs/tests/fixtures/bootstrap_error_codes.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/PersonCert/person_cert_tier_vectors.json:admin/rust/household-rs/tests/fixtures/person_cert_tier_vectors.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/SecureUpgrade/secure_upgrade_transcript_vectors.json:admin/rust/household-rs/tests/fixtures/secure_upgrade_transcript_vectors.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/InstanceStatus/instance_status_codes.json:admin/rust/store-rs/tests/fixtures/instance_status_codes.json"
  "optional:Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/ClawUnavailableReasonCode/claw_unavailable_reason_codes.json:admin/rust/core-rs/tests/fixtures/claw_unavailable_reason_codes.json"
)

# Write the theyos source for $1 into the file $2.
# Echoes one of: present | absent | error
materialize_source() {
  local path="$1" dest="$2"
  if [[ -n "${THEYOS_DIR:-}" ]]; then
    if [[ -L "${THEYOS_DIR}/${path}" ]]; then
      echo error
    elif [[ -f "${THEYOS_DIR}/${path}" ]]; then
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
  requirement="${pair%%:*}"
  rest="${pair#*:}"
  ios="${rest%%:*}"
  src="${rest#*:}"
  ios_tmp="$(mktemp "${TMP_DIR}/ios.XXXXXX")"
  if ! materialize_tracked_ios_file "${ios}" "${ios_tmp}"; then
    DRIFT=1
    continue
  fi

  src_tmp="$(mktemp)"
  case "$(materialize_source "${src}" "${src_tmp}")" in
    absent)
      if [[ "${requirement}" == "required" ]]; then
        if [[ -n "${THEYOS_DIR:-}" ]]; then
          echo "::error::required theyos source missing in local THEYOS_DIR=${THEYOS_DIR}: ${src}"
          echo "  verify THEYOS_DIR or run: THEYOS_DIR=<path> scripts/check-cross-repo-fixtures.sh"
        else
          echo "::error::required theyos source missing at theyos@${THEYOS_SHA}: ${src}"
          echo "  local/dev check: THEYOS_DIR=<path> scripts/check-cross-repo-fixtures.sh"
          echo "  CI fix: bump scripts/cross-repo-contract.sha to a remote theyos SHA that contains ${src}"
        fi
        DRIFT=1
      else
        echo "skip ${ios}: optional theyos source ${src} not present at the pinned point yet"
      fi
      ;;
    error)
      echo "::error::could not read theyos source ${src} at theyos@${THEYOS_SHA} (network error)"
      DRIFT=1
      ;;
    present)
      if diff -u "${src_tmp}" "${ios_tmp}" >/dev/null; then
        echo "✓ ${ios} matches theyos:${src}"
      else
        echo "::error::contract drift: ${ios} differs from theyos:${src}"
        echo "  re-sync with: THEYOS_DIR=<theyos> scripts/sync-cross-repo-fixtures.sh"
        diff -u "${src_tmp}" "${ios_tmp}" || true
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
