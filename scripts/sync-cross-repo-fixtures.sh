#!/bin/bash
# Syncs cross-language test fixtures from the theyos repo into SoyehtCoreTests.
#
# Run this after theyos generates new fixture data to keep the iOS tests in sync.
# Fixture files are checked into this repo; this script refreshes them.
#
# Usage:
#   scripts/sync-cross-repo-fixtures.sh
#   THEYOS_DIR=/path/to/theyos scripts/sync-cross-repo-fixtures.sh
#   SOYEHT_SYNC_ONLY=claw-store THEYOS_DIR=/path/to/theyos scripts/sync-cross-repo-fixtures.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

THEYOS_DIR="${THEYOS_DIR:?THEYOS_DIR must be set (path to local theyos checkout)}"

if [[ ! -d "${THEYOS_DIR}" ]]; then
    echo "error: theyos repo not found at ${THEYOS_DIR}" >&2
    exit 1
fi

TESTS="${REPO_ROOT}/Packages/SoyehtCore/Tests/SoyehtCoreTests"

# C4: Claw Store v1 route/wire contract + household docs mirror.
sync_claw_store_contract() {
    local src_contract="${THEYOS_DIR}/admin/contracts/claw-store/v1/contract.json"
    local src_household_docs="${THEYOS_DIR}/docs/contracts/claw-store-household-v1.json"
    local dest_dir="${TESTS}/Fixtures/claw-store/v1"
    local dest_docs_dir="${REPO_ROOT}/docs/contracts"

    if [[ ! -f "${src_contract}" ]]; then
        echo "error: Claw Store v1 contract not found at ${src_contract}" >&2
        exit 1
    fi
    if [[ ! -f "${src_household_docs}" ]]; then
        echo "error: Claw Store household docs mirror not found at ${src_household_docs}" >&2
        exit 1
    fi

    mkdir -p "${dest_dir}"
    mkdir -p "${dest_docs_dir}"
    cp "${src_contract}" "${dest_dir}/contract.json"
    cp "${src_household_docs}" "${dest_docs_dir}/claw-store-household-v1.json"
    echo "✓ claw-store/v1/contract.json"
    echo "synced docs/contracts/claw-store-household-v1.json"

    # Regenerate the Swift contract constants from the just-synced contract so the
    # generated file never drifts from the vendored fixture. The drift guard
    # (ClawStoreContractConstantsGuardTests) is the safety net if this is skipped.
    uv run python "${SCRIPT_DIR}/gen-claw-store-contract-constants.py"
}

sync_claw_store_contract

if [[ "${SOYEHT_SYNC_ONLY:-}" == "claw-store" ]]; then
    echo ""
    echo "Sync complete. Commit the updated fixture files if they changed."
    exit 0
fi

# ── T039e: avatar derivation (specs/005-soyeht-onboarding/contracts/) ─────────
SRC_CONTRACTS="${THEYOS_DIR}/specs/005-soyeht-onboarding/contracts"
mkdir -p "${TESTS}/HouseholdFixtures/Avatar"
cp "${SRC_CONTRACTS}/avatar-derivation-fixtures.csv" \
   "${TESTS}/HouseholdFixtures/Avatar/avatar-derivation-fixtures.csv"
echo "✓ avatar-derivation-fixtures.csv"

# ── FR-045: emoji security code ───────────────────────────────────────────────
mkdir -p "${TESTS}/HouseholdFixtures/EmojiSecurityCode"
cp "${SRC_CONTRACTS}/emoji-security-code-fixtures.csv" \
   "${TESTS}/HouseholdFixtures/EmojiSecurityCode/emoji-security-code-fixtures.csv"
cp "${SRC_CONTRACTS}/emoji-security-code-wordlist.csv" \
   "${TESTS}/HouseholdFixtures/EmojiSecurityCode/emoji-security-code-wordlist.csv"
echo "✓ emoji-security-code-fixtures.csv + emoji-security-code-wordlist.csv"

# ── T039d: owner-cert CBOR (admin/rust/server-rs/tests/fixtures/) ─────────────
SRC_FIXTURES="${THEYOS_DIR}/admin/rust/server-rs/tests/fixtures"
mkdir -p "${TESTS}/HouseholdFixtures/OwnerCert"
cp "${SRC_FIXTURES}/owner_cert_auth.cbor" \
   "${TESTS}/HouseholdFixtures/OwnerCert/owner_cert_auth.cbor"
echo "✓ owner_cert_auth.cbor"

# ── T067b: casa_nasceu push payload ───────────────────────────────────────────
mkdir -p "${TESTS}/Fixtures/push"
cp "${SRC_FIXTURES}/casa_nasceu_push.json" \
   "${TESTS}/Fixtures/push/casa-nasceu.json"
echo "✓ casa-nasceu.json (push payload)"

# ── PR-B: guest-image failure-code contract (admin/rust/core-rs/tests/fixtures/) ──
GUEST_IMAGE_FIXTURE="${THEYOS_DIR}/admin/rust/core-rs/tests/fixtures/guest_image_failure_codes.json"
if [[ ! -f "${GUEST_IMAGE_FIXTURE}" ]]; then
    echo "error: guest-image failure-code fixture not found at ${GUEST_IMAGE_FIXTURE}" >&2
    exit 1
fi
mkdir -p "${TESTS}/HouseholdFixtures/GuestImageFailureCode"
cp "${GUEST_IMAGE_FIXTURE}" \
   "${TESTS}/HouseholdFixtures/GuestImageFailureCode/guest_image_failure_codes.json"
echo "✓ guest_image_failure_codes.json (guest-image failure-code contract)"

# ── PR-B: bootstrap/onboarding error-code contract (admin/rust/household-rs/tests/fixtures/) ──
BOOTSTRAP_ERROR_FIXTURE="${THEYOS_DIR}/admin/rust/household-rs/tests/fixtures/bootstrap_error_codes.json"
if [[ ! -f "${BOOTSTRAP_ERROR_FIXTURE}" ]]; then
    echo "error: bootstrap error-code fixture not found at ${BOOTSTRAP_ERROR_FIXTURE}" >&2
    exit 1
fi
mkdir -p "${TESTS}/HouseholdFixtures/BootstrapErrorCode"
cp "${BOOTSTRAP_ERROR_FIXTURE}" \
   "${TESTS}/HouseholdFixtures/BootstrapErrorCode/bootstrap_error_codes.json"
echo "✓ bootstrap_error_codes.json (bootstrap error-code contract)"

# ── InstanceStatus: instance lifecycle status wire contract (admin/rust/store-rs/tests/fixtures/) ──
INSTANCE_STATUS_FIXTURE="${THEYOS_DIR}/admin/rust/store-rs/tests/fixtures/instance_status_codes.json"
if [[ ! -f "${INSTANCE_STATUS_FIXTURE}" ]]; then
    echo "error: instance-status fixture not found at ${INSTANCE_STATUS_FIXTURE}" >&2
    exit 1
fi
mkdir -p "${TESTS}/HouseholdFixtures/InstanceStatus"
cp "${INSTANCE_STATUS_FIXTURE}" \
   "${TESTS}/HouseholdFixtures/InstanceStatus/instance_status_codes.json"
echo "✓ instance_status_codes.json (instance lifecycle status contract)"

# -- ClawUnavailableReasonCode: claw installability reason wire contract (admin/rust/core-rs/tests/fixtures/) --
UNAVAIL_REASON_FIXTURE="${THEYOS_DIR}/admin/rust/core-rs/tests/fixtures/claw_unavailable_reason_codes.json"
if [[ ! -f "${UNAVAIL_REASON_FIXTURE}" ]]; then
    echo "error: claw-unavailable-reason fixture not found at ${UNAVAIL_REASON_FIXTURE}" >&2
    exit 1
fi
mkdir -p "${TESTS}/HouseholdFixtures/ClawUnavailableReasonCode"
cp "${UNAVAIL_REASON_FIXTURE}" \
   "${TESTS}/HouseholdFixtures/ClawUnavailableReasonCode/claw_unavailable_reason_codes.json"
echo "✓ claw_unavailable_reason_codes.json (claw installability reason contract)"

echo ""
echo "Sync complete. Commit the updated fixture files if they changed."
