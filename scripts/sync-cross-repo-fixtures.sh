#!/bin/bash
# Syncs cross-language test fixtures from the theyos repo into SoyehtCoreTests.
#
# Run this after theyos generates new fixture data to keep the iOS tests in sync.
# Fixture files are checked into this repo; this script refreshes them.
#
# Usage:
#   scripts/sync-cross-repo-fixtures.sh
#   THEYOS_DIR=/path/to/theyos scripts/sync-cross-repo-fixtures.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

THEYOS_DIR="${THEYOS_DIR:-/Users/macstudio/Documents/theyos}"

if [[ ! -d "${THEYOS_DIR}" ]]; then
    echo "error: theyos repo not found at ${THEYOS_DIR}" >&2
    echo "       Set THEYOS_DIR to the local theyos checkout path." >&2
    exit 1
fi

TESTS="${REPO_ROOT}/Packages/SoyehtCore/Tests/SoyehtCoreTests"

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

echo ""
echo "Sync complete. Commit the updated fixture files if they changed."
