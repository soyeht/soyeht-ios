#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-a2-corpus-guard-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

VENDORED_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_site_a2_r1_semantic_corpus_v1.json"
PIN_REL="scripts/owner-site-a2-r1-corpus.pin"
AUTHORITY_REPOSITORY="${THEYOS_AUTHORITY_REPOSITORY:-https://github.com/soyeht/theyos.git}"
AUTHORITY_DIR="${TMP_ROOT}/theyos-authority.git"

if ! git clone --quiet --bare --single-branch --branch main \
  "${AUTHORITY_REPOSITORY}" "${AUTHORITY_DIR}"; then
  echo "error: unable to prepare authoritative theyos mirror for A2-R1 guard test" >&2
  exit 1
fi

make_ios_root() {
  local label="$1"
  local root="${TMP_ROOT}/${label}"
  mkdir -p "${root}/scripts" "$(dirname "${root}/${VENDORED_REL}")"
  cp "${REPO_ROOT}/scripts/check-owner-site-a2-r1-corpus-fixture.sh" "${root}/scripts/"
  cp "${REPO_ROOT}/${PIN_REL}" "${root}/${PIN_REL}"
  cp "${REPO_ROOT}/${VENDORED_REL}" "${root}/${VENDORED_REL}"
  git -C "${root}" init --quiet
  git -C "${root}" config user.name "a2-corpus-guard-test"
  git -C "${root}" config user.email "a2-corpus-guard@example.invalid"
  git -C "${root}" add .
  git -C "${root}" commit --quiet -m fixture
  printf '%s\n' "${root}"
}

run_guard() {
  local root="$1"
  OWNER_SITE_A2_CORPUS_REPO_ROOT="${root}" \
    THEYOS_AUTHORITY_REPOSITORY="file://${AUTHORITY_DIR}" \
    "${root}/scripts/check-owner-site-a2-r1-corpus-fixture.sh"
}

expect_guard_failure() {
  local root="$1" label="$2" expected="$3"
  if run_guard "${root}" >"${TMP_ROOT}/${label}.log" 2>&1; then
    echo "error: A2-R1 corpus guard accepted ${label}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" "${TMP_ROOT}/${label}.log"; then
    echo "error: ${label} failed before its intended guard: ${expected}" >&2
    exit 1
  fi
  echo "PASS ${label}_refused"
}

root="$(make_ios_root exact)"
run_guard "${root}" >/dev/null
echo "PASS exact_a2_r1_corpus"

root="$(make_ios_root vendor-drift)"
printf '\n' >> "${root}/${VENDORED_REL}"
git -C "${root}" add "${VENDORED_REL}"
expect_guard_failure "${root}" vendor_drift "A2-R1 vendored corpus SHA-256 differs"

root="$(make_ios_root duplicate)"
mkdir -p "${root}/duplicate"
cp "${root}/${VENDORED_REL}" "${root}/duplicate/owner_site_a2_r1_semantic_corpus_v1.json"
git -C "${root}" add duplicate
expect_guard_failure "${root}" duplicate_copy "A2-R1 corpus guard rejects a missing, duplicated, or ambiguous vendored corpus path"

root="$(make_ios_root renamed-alias)"
mkdir -p "${root}/alias"
cp "${root}/${VENDORED_REL}" "${root}/alias/frozen-a2-r1-copy.json"
git -C "${root}" add alias
expect_guard_failure "${root}" renamed_alias_copy "A2-R1 corpus guard rejects a duplicated or ambiguous vendored corpus blob"

root="$(make_ios_root path-ref-drift)"
printf '%s\n' \
  'theyos_commit=0000000000000000000000000000000000000000' \
  'source_path=admin/contracts/mobile-claw-vpn/v1/not_the_corpus.json' \
  'sha256=dde67030a035928d0a859a19fc7dcf14ea8e8fa54643e9f66302652740548330' \
  > "${root}/${PIN_REL}"
git -C "${root}" add "${PIN_REL}"
expect_guard_failure "${root}" path_ref_drift "A2-R1 corpus pin differs from the required commit/path/SHA triple"

root="$(make_ios_root expected-hash-drift)"
printf '%s\n' \
  'theyos_commit=b201a075884eb1ac77f2b0f6904c38866bbafb5b' \
  'source_path=admin/contracts/mobile-claw-vpn/v1/owner_site_a2_r1_semantic_corpus_v1.json' \
  'sha256=0000000000000000000000000000000000000000000000000000000000000000' \
  > "${root}/${PIN_REL}"
git -C "${root}" add "${PIN_REL}"
expect_guard_failure "${root}" expected_hash_drift "A2-R1 corpus pin differs from the required commit/path/SHA triple"

root="$(make_ios_root missing)"
rm "${root}/${VENDORED_REL}"
git -C "${root}" add -u
expect_guard_failure "${root}" missing_vendor "A2-R1 corpus guard rejects a missing, duplicated, or ambiguous vendored corpus path"

root="$(make_ios_root vendor-symlink)"
mv "${root}/${VENDORED_REL}" "${root}/${VENDORED_REL}.target"
ln -s "$(basename "${VENDORED_REL}").target" "${root}/${VENDORED_REL}"
git -C "${root}" add -A
expect_guard_failure "${root}" vendor_symlink "A2-R1 corpus guard requires an ordinary 100644 Git blob"

root="$(make_ios_root pin-symlink)"
mv "${root}/${PIN_REL}" "${root}/${PIN_REL}.target"
ln -s "$(basename "${PIN_REL}").target" "${root}/${PIN_REL}"
git -C "${root}" add -A
expect_guard_failure "${root}" pin_symlink "A2-R1 corpus guard requires an ordinary 100644 Git blob"

echo "PASS owner_site_a2_r1_corpus_guard"
