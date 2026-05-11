#!/bin/bash
# Downloads the theyos-engine release bundle from GitHub Releases and places the
# engine plus required IPC helpers in THEYOS_BUILD_DIR for embed-engine.sh.
#
# Environment:
#   ENGINE_VERSION   — semver tag without "v" prefix (default: 0.1.11)
#   THEYOS_BUILD_DIR — destination directory (default: /tmp/theyos-engine-dist)
#   GITHUB_TOKEN     — optional; avoids API rate-limiting on CI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE_VERSION="${ENGINE_VERSION:-0.1.11}"
ARCH="arm64"
TARBALL="theyos-engine-${ENGINE_VERSION}-macos-${ARCH}.tar.gz"
RELEASE_URL="https://github.com/soyeht/theyos/releases/download/v${ENGINE_VERSION}/${TARBALL}"
THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-/tmp/theyos-engine-dist}"
ENGINE_DEST="${THEYOS_BUILD_DIR}/theyos-engine"
VERSION_SENTINEL="${THEYOS_BUILD_DIR}/engine-version.txt"
REQUIRED_BINARIES=(theyos-engine vmrunner_macos_ipc store-ipc terminal-ipc theyos-ssh)

has_required_binaries() {
    for binary in "${REQUIRED_BINARIES[@]}"; do
        if [ ! -f "${THEYOS_BUILD_DIR}/${binary}" ]; then
            return 1
        fi
    done
    return 0
}

# ── Idempotency: skip if sentinel confirms the right version is already present ─
CACHED_VERSION="$(cat "${VERSION_SENTINEL}" 2>/dev/null || true)"
if [[ "${CACHED_VERSION}" == "${ENGINE_VERSION}" || "${CACHED_VERSION}" == "v${ENGINE_VERSION}" ]]; then
    if has_required_binaries; then
        echo "${ENGINE_VERSION}" > "${VERSION_SENTINEL}"
        echo "→ theyos-engine v${ENGINE_VERSION} already present; skipping download."
        exit 0
    fi
    echo "→ theyos-engine v${ENGINE_VERSION} cache is missing helpers; downloading again."
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

for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "${SCRATCH}/${binary}" ]; then
        echo "error: ${binary} not found in ${TARBALL}" >&2
        echo "       The macOS app bundle needs all engine IPC helpers." >&2
        exit 1
    fi
    cp "${SCRATCH}/${binary}" "${THEYOS_BUILD_DIR}/${binary}"
    chmod +x "${THEYOS_BUILD_DIR}/${binary}"
done

# Write a normalized version sentinel so future builds can skip correctly.
echo "${ENGINE_VERSION}" > "${VERSION_SENTINEL}"

echo "✓ theyos-engine v${ENGINE_VERSION} → ${ENGINE_DEST}"
