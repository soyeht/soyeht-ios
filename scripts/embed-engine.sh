#!/bin/bash
# Copies the theyos-engine binary into Soyeht.app/Contents/Helpers/
# and signs it with the same Developer ID used for the app.
#
# Lookup order for the binary:
#   1. $THEYOS_BUILD_DIR/theyos-engine  (local Rust build or fetch-engine.sh output)
#   2. Skipped gracefully with a warning (non-fatal for Debug builds)
#
# For release builds, run scripts/fetch-engine.sh first to download the
# pre-built binary from GitHub Releases into /tmp/theyos-engine-dist/.
set -euo pipefail

THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-/tmp/theyos-engine-dist}"
ENGINE_SRC="${THEYOS_BUILD_DIR}/theyos-engine"
HELPERS_DIR="${CODESIGNING_FOLDER_PATH}/Contents/Helpers"
ENGINE_DEST="${HELPERS_DIR}/theyos-engine"

if [ ! -f "${ENGINE_SRC}" ]; then
    echo "warning: theyos-engine not found at ${ENGINE_SRC}; skipping embed."
    echo "         Run scripts/fetch-engine.sh or set THEYOS_BUILD_DIR to a local build."
    exit 0
fi

mkdir -p "${HELPERS_DIR}"
cp "${ENGINE_SRC}" "${ENGINE_DEST}"
chmod +x "${ENGINE_DEST}"

# Sign with the same identity as the host app unless this is an ad-hoc (debug) build.
if [ "${CODE_SIGN_IDENTITY}" != "-" ] && [ -n "${CODE_SIGN_IDENTITY}" ]; then
    ENTITLEMENTS_PATH="${SRCROOT}/SoyehtMac/SoyehtEngine.entitlements"
    codesign \
        --force \
        --sign "${CODE_SIGN_IDENTITY}" \
        --timestamp \
        --options runtime \
        --entitlements "${ENTITLEMENTS_PATH}" \
        "${ENGINE_DEST}"
    echo "Signed theyos-engine with ${CODE_SIGN_IDENTITY}"
else
    echo "Skipping codesign (ad-hoc / development build)"
fi

echo "Embedded theyos-engine → ${ENGINE_DEST}"
