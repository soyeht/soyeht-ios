#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-contract-guard-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

IOS_ROOT="${TMP_ROOT}/ios"
THEYOS_ROOT="${TMP_ROOT}/theyos"
mkdir -p "${IOS_ROOT}/scripts" "${THEYOS_ROOT}"
cp "${SCRIPT_DIR}/check-cross-repo-fixtures.sh" "${IOS_ROOT}/scripts/"

# Keep this list aligned with the required pairs in check-cross-repo-fixtures.sh.
PAIRS=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json:admin/contracts/claw-store/v1/contract.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/api_shapes.json:admin/contracts/mobile-claw-vpn/v1/api_shapes.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json:admin/contracts/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json"
  "docs/contracts/claw-store-household-v1.json:docs/contracts/claw-store-household-v1.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/GuestImageFailureCode/guest_image_failure_codes.json:admin/rust/core-rs/tests/fixtures/guest_image_failure_codes.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/BootstrapErrorCode/bootstrap_error_codes.json:admin/rust/household-rs/tests/fixtures/bootstrap_error_codes.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/PersonCert/person_cert_tier_vectors.json:admin/rust/household-rs/tests/fixtures/person_cert_tier_vectors.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/SecureUpgrade/secure_upgrade_transcript_vectors.json:admin/rust/household-rs/tests/fixtures/secure_upgrade_transcript_vectors.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/InstanceStatus/instance_status_codes.json:admin/rust/store-rs/tests/fixtures/instance_status_codes.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/ClawUnavailableReasonCode/claw_unavailable_reason_codes.json:admin/rust/core-rs/tests/fixtures/claw_unavailable_reason_codes.json"
)

for pair in "${PAIRS[@]}"; do
  ios_path="${pair%%:*}"
  theyos_path="${pair#*:}"
  mkdir -p "$(dirname "${IOS_ROOT}/${ios_path}")" "$(dirname "${THEYOS_ROOT}/${theyos_path}")"
  cp "${REPO_ROOT}/${ios_path}" "${IOS_ROOT}/${ios_path}"
  cp "${REPO_ROOT}/${ios_path}" "${THEYOS_ROOT}/${theyos_path}"
done

git -C "${THEYOS_ROOT}" init --quiet
git -C "${THEYOS_ROOT}" config user.name "contract-guard-test"
git -C "${THEYOS_ROOT}" config user.email "contract-guard@example.invalid"
git -C "${THEYOS_ROOT}" add .
git -C "${THEYOS_ROOT}" commit --quiet -m fixture
PIN="$(git -C "${THEYOS_ROOT}" rev-parse HEAD)"
printf '%s\n' "${PIN}" > "${IOS_ROOT}/scripts/cross-repo-contract.sha"

git -C "${IOS_ROOT}" init --quiet
git -C "${IOS_ROOT}" config user.name "contract-guard-test"
git -C "${IOS_ROOT}" config user.email "contract-guard@example.invalid"
git -C "${IOS_ROOT}" add .
git -C "${IOS_ROOT}" commit --quiet -m fixture

run_guard() {
  THEYOS_DIR="${THEYOS_ROOT}" SOYEHT_REQUIRE_LOCAL_PIN=1 \
    "${IOS_ROOT}/scripts/check-cross-repo-fixtures.sh"
}

expect_guard_failure() {
  local label="$1"
  if run_guard >"${TMP_ROOT}/${label}.log" 2>&1; then
    echo "error: guard accepted ${label} drift" >&2
    exit 1
  fi
  echo "PASS ${label}_drift_refused"
}

run_guard >/dev/null
echo "PASS exact_fixture_and_pin"

OWNER_VENDOR_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json"
OWNER_SOURCE_REL="admin/contracts/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json"

printf '\n' >> "${IOS_ROOT}/${OWNER_VENDOR_REL}"
git -C "${IOS_ROOT}" add "${OWNER_VENDOR_REL}"
expect_guard_failure vendor_only
cp "${THEYOS_ROOT}/${OWNER_SOURCE_REL}" "${IOS_ROOT}/${OWNER_VENDOR_REL}"
git -C "${IOS_ROOT}" add "${OWNER_VENDOR_REL}"
run_guard >/dev/null

cp "${IOS_ROOT}/${OWNER_VENDOR_REL}" "${TMP_ROOT}/vendor-target.json"
rm "${IOS_ROOT}/${OWNER_VENDOR_REL}"
ln -s "${TMP_ROOT}/vendor-target.json" "${IOS_ROOT}/${OWNER_VENDOR_REL}"
git -C "${IOS_ROOT}" add "${OWNER_VENDOR_REL}"
expect_guard_failure vendor_symlink
rm "${IOS_ROOT}/${OWNER_VENDOR_REL}"
cp "${THEYOS_ROOT}/${OWNER_SOURCE_REL}" "${IOS_ROOT}/${OWNER_VENDOR_REL}"
git -C "${IOS_ROOT}" add "${OWNER_VENDOR_REL}"
run_guard >/dev/null

printf '\n' >> "${THEYOS_ROOT}/${OWNER_SOURCE_REL}"
expect_guard_failure source_only
cp "${IOS_ROOT}/${OWNER_VENDOR_REL}" "${THEYOS_ROOT}/${OWNER_SOURCE_REL}"
run_guard >/dev/null

printf '%040d\n' 0 > "${IOS_ROOT}/scripts/cross-repo-contract.sha"
git -C "${IOS_ROOT}" add scripts/cross-repo-contract.sha
expect_guard_failure pin_only
printf '%s\n' "${PIN}" > "${IOS_ROOT}/scripts/cross-repo-contract.sha"
git -C "${IOS_ROOT}" add scripts/cross-repo-contract.sha
run_guard >/dev/null

printf '%s\n' "${PIN}" > "${TMP_ROOT}/pin-target.sha"
rm "${IOS_ROOT}/scripts/cross-repo-contract.sha"
ln -s "${TMP_ROOT}/pin-target.sha" "${IOS_ROOT}/scripts/cross-repo-contract.sha"
git -C "${IOS_ROOT}" add scripts/cross-repo-contract.sha
expect_guard_failure pin_symlink
rm "${IOS_ROOT}/scripts/cross-repo-contract.sha"
printf '%s\n' "${PIN}" > "${IOS_ROOT}/scripts/cross-repo-contract.sha"
git -C "${IOS_ROOT}" add scripts/cross-repo-contract.sha
run_guard >/dev/null

echo "PASS cross_repo_fixture_guard"
