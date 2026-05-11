#!/bin/bash
# Downloads the theyos-engine release binary from GitHub Releases and places it
# at THEYOS_BUILD_DIR/theyos-engine so embed-engine.sh can pick it up.
#
# Environment:
#   ENGINE_VERSION   — semver tag without "v" prefix (default: 0.1.9)
#   THEYOS_BUILD_DIR — destination directory (default: /tmp/theyos-engine-dist)
#   GITHUB_TOKEN     — optional; avoids API rate-limiting on CI
set -euo pipefail

ENGINE_VERSION="${ENGINE_VERSION:-0.1.9}"
ARCH="arm64"
TARBALL="theyos-engine-${ENGINE_VERSION}-macos-${ARCH}.tar.gz"
RELEASE_URL="https://github.com/soyeht/theyos/releases/download/v${ENGINE_VERSION}/${TARBALL}"
THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-/tmp/theyos-engine-dist}"
ENGINE_DEST="${THEYOS_BUILD_DIR}/theyos-engine"

if [ -f "${ENGINE_DEST}" ]; then
    echo "→ theyos-engine v${ENGINE_VERSION} already at ${ENGINE_DEST}; skipping download."
    exit 0
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

echo "→ Extracting..."
tar -xzf "${SCRATCH}/${TARBALL}" -C "${SCRATCH}/"

if [ ! -f "${SCRATCH}/theyos-engine" ]; then
    echo "error: theyos-engine binary not found in tarball" >&2
    exit 1
fi

cp "${SCRATCH}/theyos-engine" "${ENGINE_DEST}"
chmod +x "${ENGINE_DEST}"

echo "✓ theyos-engine v${ENGINE_VERSION} → ${ENGINE_DEST}"
