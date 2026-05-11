#!/bin/bash
# Downloads the theyos-engine release binary from GitHub Releases and places it
# at THEYOS_BUILD_DIR/theyos-engine so embed-engine.sh can pick it up.
#
# Environment:
#   ENGINE_VERSION   — semver tag without "v" prefix (default: 0.1.9)
#   THEYOS_BUILD_DIR — destination directory (default: /tmp/theyos-engine-dist)
#   GITHUB_TOKEN     — optional; avoids API rate-limiting on CI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE_VERSION="${ENGINE_VERSION:-0.1.9}"
ARCH="arm64"
TARBALL="theyos-engine-${ENGINE_VERSION}-macos-${ARCH}.tar.gz"
RELEASE_URL="https://github.com/soyeht/theyos/releases/download/v${ENGINE_VERSION}/${TARBALL}"
THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-/tmp/theyos-engine-dist}"
ENGINE_DEST="${THEYOS_BUILD_DIR}/theyos-engine"
VERSION_SENTINEL="${THEYOS_BUILD_DIR}/engine-version.txt"

# ── Idempotency: skip if sentinel confirms the right version is already present ─
if grep -qx "${ENGINE_VERSION}" "${VERSION_SENTINEL}" 2>/dev/null; then
    echo "→ theyos-engine v${ENGINE_VERSION} already present; skipping download."
    exit 0
fi

# ── Integrity: resolve pinned SHA-256 for this version ────────────────────────
CHECKSUMS_FILE="${SCRIPT_DIR}/theyos-engine.sha256"
EXPECTED_SHA=$(grep "^${ENGINE_VERSION}[[:space:]]" "${CHECKSUMS_FILE}" 2>/dev/null | awk '{print $2}')
if [[ -z "${EXPECTED_SHA}" ]]; then
    echo "error: No checksum found for ENGINE_VERSION=${ENGINE_VERSION} in ${CHECKSUMS_FILE}" >&2
    echo "       Add a line: ${ENGINE_VERSION}  <sha256_of_tarball>" >&2
    exit 1
fi

mkdir -p "${THEYOS_BUILD_DIR}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

echo "→ Downloading theyos-engine v${ENGINE_VERSION}..."
CURL_ARGS=(-fsSL "${RELEASE_URL}" -o "${SCRATCH}/${TARBALL}")
if [ -n "${GITHUB_TOKEN:-}" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi
curl "${CURL_ARGS[@]}"

# ── Verify tarball integrity before extracting ────────────────────────────────
ACTUAL_SHA=$(shasum -a 256 "${SCRATCH}/${TARBALL}" | awk '{print $1}')
if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
    echo "error: SHA-256 mismatch for ${TARBALL}" >&2
    echo "  expected: ${EXPECTED_SHA}" >&2
    echo "  got:      ${ACTUAL_SHA}" >&2
    exit 1
fi
echo "✓ SHA-256 verified"

echo "→ Extracting..."
tar -xzf "${SCRATCH}/${TARBALL}" -C "${SCRATCH}/"

if [ ! -f "${SCRATCH}/theyos-engine" ]; then
    echo "error: theyos-engine binary not found in tarball" >&2
    exit 1
fi

cp "${SCRATCH}/theyos-engine" "${ENGINE_DEST}"
chmod +x "${ENGINE_DEST}"

# Write version sentinel so the next run skips correctly even when ENGINE_VERSION changes.
if [ -f "${SCRATCH}/engine-version.txt" ]; then
    cp "${SCRATCH}/engine-version.txt" "${VERSION_SENTINEL}"
else
    echo "${ENGINE_VERSION}" > "${VERSION_SENTINEL}"
fi

echo "✓ theyos-engine v${ENGINE_VERSION} → ${ENGINE_DEST}"
