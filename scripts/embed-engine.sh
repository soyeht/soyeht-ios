#!/bin/bash
# Copies the theyos Rust engine binary into Soyeht.app/Contents/Helpers/
# and signs it with the same Developer ID used for the app.
#
# Set THEYOS_BUILD_DIR to override the default binary location.
set -euo pipefail

THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-${SRCROOT}/../../../theyos/target/aarch64-apple-darwin/release}"
ENGINE_SRC="${THEYOS_BUILD_DIR}/server"
HELPERS_DIR="${CODESIGNING_FOLDER_PATH}/Contents/Helpers"
ENGINE_DEST="${HELPERS_DIR}/soyeht-engine"

if [ ! -f "${ENGINE_SRC}" ]; then
    echo "warning: soyeht-engine not found at ${ENGINE_SRC}; skipping embed. Set THEYOS_BUILD_DIR to override."
    exit 0
fi

mkdir -p "${HELPERS_DIR}"
cp "${ENGINE_SRC}" "${ENGINE_DEST}"
chmod +x "${ENGINE_DEST}"

# Sign with the same identity as the host app unless this is an ad-hoc (debug) build.
if [ "${CODE_SIGN_IDENTITY}" != "-" ] && [ -n "${CODE_SIGN_IDENTITY}" ]; then
    ENTITLEMENTS_PATH="${SRCROOT}/SoyehtMac/SoyehtMac.entitlements"
    if [ "${CONFIGURATION}" = "Debug" ]; then
        ENTITLEMENTS_PATH="${SRCROOT}/SoyehtMac/SoyehtMacDebug.entitlements"
    fi
    codesign \
        --force \
        --sign "${CODE_SIGN_IDENTITY}" \
        --timestamp \
        --options runtime \
        --entitlements "${ENTITLEMENTS_PATH}" \
        "${ENGINE_DEST}"
    echo "Signed soyeht-engine with ${CODE_SIGN_IDENTITY}"
else
    echo "Skipping codesign (ad-hoc / development build)"
fi

echo "Embedded soyeht-engine → ${ENGINE_DEST}"
