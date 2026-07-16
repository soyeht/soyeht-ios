#!/bin/bash
# Fail-closed integrity guard for the frozen A2-R1 semantic corpus.
#
# This artifact intentionally has a dedicated pin rather than sharing the
# general cross-repo contract pin: its cryptographic corpus is versioned and
# reviewed independently of unrelated contract-fixture sync debt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${OWNER_SITE_A2_CORPUS_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PIN_REL="scripts/owner-site-a2-r1-corpus.pin"
VENDORED_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_site_a2_r1_semantic_corpus_v1.json"
EXPECTED_COMMIT="b201a075884eb1ac77f2b0f6904c38866bbafb5b"
EXPECTED_SOURCE_PATH="admin/contracts/mobile-claw-vpn/v1/owner_site_a2_r1_semantic_corpus_v1.json"
EXPECTED_SHA256="dde67030a035928d0a859a19fc7dcf14ea8e8fa54643e9f66302652740548330"

materialize_tracked_blob() {
  local relative_path="$1" destination="$2" entry mode object stage ignored absolute_path

  entry="$(git -C "${REPO_ROOT}" ls-files --stage -- "${relative_path}")"
  if [[ -z "${entry}" || "${entry}" == *$'\n'* ]]; then
    echo "::error::A2-R1 corpus guard requires exactly one tracked file: ${relative_path}" >&2
    return 1
  fi
  read -r mode object stage ignored <<< "${entry}"
  if [[ "${mode}" != "100644" || "${stage}" != "0" ]]; then
    echo "::error::A2-R1 corpus guard requires an ordinary 100644 Git blob: ${relative_path}" >&2
    return 1
  fi

  absolute_path="${REPO_ROOT}/${relative_path}"
  if [[ -L "${absolute_path}" || ! -f "${absolute_path}" ]]; then
    echo "::error::A2-R1 corpus guard rejects missing or non-regular checkout file: ${relative_path}" >&2
    return 1
  fi
  git -C "${REPO_ROOT}" cat-file blob "${object}" > "${destination}"
  if ! cmp -s "${destination}" "${absolute_path}"; then
    echo "::error::A2-R1 corpus guard rejects a working copy that differs from its tracked blob: ${relative_path}" >&2
    return 1
  fi

  MATERIALIZED_TRACKED_BLOB_OBJECT="${object}"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

PIN_BLOB="${TMP_DIR}/pin"
EXPECTED_PIN_BLOB="${TMP_DIR}/expected-pin"
VENDORED_BLOB="${TMP_DIR}/vendored-corpus"
materialize_tracked_blob "${PIN_REL}" "${PIN_BLOB}"
printf 'theyos_commit=%s\nsource_path=%s\nsha256=%s\n' \
  "${EXPECTED_COMMIT}" "${EXPECTED_SOURCE_PATH}" "${EXPECTED_SHA256}" > "${EXPECTED_PIN_BLOB}"
if ! cmp -s "${PIN_BLOB}" "${EXPECTED_PIN_BLOB}"; then
  echo "::error::A2-R1 corpus pin differs from the required commit/path/SHA triple" >&2
  exit 1
fi

same_named="$(git -C "${REPO_ROOT}" ls-files | awk -F/ '$NF == "owner_site_a2_r1_semantic_corpus_v1.json" { print }')"
if [[ "${same_named}" != "${VENDORED_REL}" ]]; then
  echo "::error::A2-R1 corpus guard rejects a missing, duplicated, or ambiguous vendored corpus path" >&2
  exit 1
fi

materialize_tracked_blob "${VENDORED_REL}" "${VENDORED_BLOB}"
VENDORED_BLOB_OBJECT="${MATERIALIZED_TRACKED_BLOB_OBJECT}"
if [[ "$(sha256_file "${VENDORED_BLOB}")" != "${EXPECTED_SHA256}" ]]; then
  echo "::error::A2-R1 vendored corpus SHA-256 differs from the frozen expected bytes" >&2
  exit 1
fi

# A frozen corpus must have one unambiguous local identity.  Checking the Git
# blob object catches byte-identical aliases even if they were given a different
# filename, which a basename-only scan would miss.
duplicate_blob_paths=()
while IFS= read -r -d '' index_entry; do
  index_header="${index_entry%%$'\t'*}"
  index_path="${index_entry#*$'\t'}"
  read -r index_mode index_object index_stage index_ignored <<< "${index_header}"
  if [[ "${index_stage}" == "0" && "${index_object}" == "${VENDORED_BLOB_OBJECT}" \
    && "${index_path}" != "${VENDORED_REL}" ]]; then
    duplicate_blob_paths+=("${index_path}")
  fi
done < <(git -C "${REPO_ROOT}" ls-files --stage -z)
if (( ${#duplicate_blob_paths[@]} != 0 )); then
  echo "::error::A2-R1 corpus guard rejects a duplicated or ambiguous vendored corpus blob" >&2
  exit 1
fi

THEYOS_AUTHORITY_REPOSITORY="${THEYOS_AUTHORITY_REPOSITORY:-https://github.com/soyeht/theyos.git}"
THEYOS_AUTHORITY_DIR="${TMP_DIR}/theyos-authority.git"
if ! git clone --quiet --bare --filter=blob:none --single-branch --branch main \
  "${THEYOS_AUTHORITY_REPOSITORY}" "${THEYOS_AUTHORITY_DIR}"; then
  echo "::error::A2-R1 corpus guard could not fetch the authoritative theyos main" >&2
  exit 1
fi

if ! git -C "${THEYOS_AUTHORITY_DIR}" cat-file -e "${EXPECTED_COMMIT}^{commit}" 2>/dev/null \
  || ! git -C "${THEYOS_AUTHORITY_DIR}" merge-base --is-ancestor \
    "${EXPECTED_COMMIT}" refs/heads/main; then
  echo "::error::A2-R1 corpus guard rejects a pin not landed on authoritative theyos/main" >&2
  exit 1
fi

SOURCE_ENTRY="$(git -C "${THEYOS_AUTHORITY_DIR}" ls-tree "${EXPECTED_COMMIT}" -- "${EXPECTED_SOURCE_PATH}")"
if [[ -z "${SOURCE_ENTRY}" || "${SOURCE_ENTRY}" == *$'\n'* ]]; then
  echo "::error::A2-R1 corpus guard rejects the canonical source path at the pinned commit" >&2
  exit 1
fi
read -r SOURCE_MODE SOURCE_TYPE SOURCE_OBJECT SOURCE_IGNORED <<< "${SOURCE_ENTRY}"
if [[ "${SOURCE_MODE}" != "100644" || "${SOURCE_TYPE}" != "blob" ]]; then
  echo "::error::A2-R1 corpus guard requires an ordinary canonical source blob" >&2
  exit 1
fi

SOURCE_BLOB="${TMP_DIR}/source-corpus"
git -C "${THEYOS_AUTHORITY_DIR}" cat-file blob "${SOURCE_OBJECT}" > "${SOURCE_BLOB}"
if [[ "$(sha256_file "${SOURCE_BLOB}")" != "${EXPECTED_SHA256}" ]]; then
  echo "::error::A2-R1 canonical corpus SHA-256 differs from the frozen expected bytes" >&2
  exit 1
fi
if ! cmp -s "${VENDORED_BLOB}" "${SOURCE_BLOB}"; then
  echo "::error::A2-R1 vendored corpus does not byte-match its pinned canonical source" >&2
  exit 1
fi

echo "A2-R1 frozen corpus matches theyos@${EXPECTED_COMMIT}:${EXPECTED_SOURCE_PATH}"
