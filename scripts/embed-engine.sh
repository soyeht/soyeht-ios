#!/bin/bash
# Copies theyos engine support binaries into Soyeht.app/Contents/Helpers/
# and the SMAppService LaunchAgent plist into Soyeht.app/Contents/Library/LaunchAgents/.
# Release builds fail if any required helper is missing.
#
# Lookup order for the binary:
#   1. $THEYOS_BUILD_DIR/theyos-engine  (fetch-engine.sh output)
#   2. $THEYOS_BUILD_DIR/server         (local Rust release build; copied as theyos-engine)
#   3. Skipped gracefully with a warning (non-fatal for Debug builds)
#
# For release builds, run scripts/fetch-engine.sh first to download the
# pre-built binary from GitHub Releases into /tmp/theyos-engine-dist/.
set -euo pipefail

THEYOS_BUILD_DIR_WAS_SET="${THEYOS_BUILD_DIR+x}"
THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR:-/tmp/theyos-engine-dist}"
ENGINE_SRC="${THEYOS_BUILD_DIR}/theyos-engine"
LOCAL_SERVER_SRC="${THEYOS_BUILD_DIR}/server"
HELPERS_DIR="${CODESIGNING_FOLDER_PATH}/Contents/Helpers"
ENGINE_DEST="${HELPERS_DIR}/theyos-engine"
LAUNCH_AGENTS_DIR="${CODESIGNING_FOLDER_PATH}/Contents/Library/LaunchAgents"
LAUNCH_AGENT_SRC="${SRCROOT}/SoyehtMac/Library/LaunchAgents/com.soyeht.engine.plist"
LAUNCH_AGENT_DEST="${LAUNCH_AGENTS_DIR}/com.soyeht.engine.plist"
REQUIRED_HELPERS=(vmrunner_macos_ipc store-ipc terminal-ipc theyos-ssh)

has_required_helpers() {
    for helper in "${REQUIRED_HELPERS[@]}"; do
        if [ ! -f "${THEYOS_BUILD_DIR}/${helper}" ]; then
            return 1
        fi
    done
    return 0
}

refresh_default_cache_if_needed() {
    if has_required_helpers; then
        return 0
    fi

    # Older local builds may have a default /tmp cache containing only
    # theyos-engine. Refresh only the default cache; explicit THEYOS_BUILD_DIR
    # usually points at a local Rust build and should not be overwritten.
    if [ -n "${THEYOS_BUILD_DIR_WAS_SET}" ] && [ "${THEYOS_BUILD_DIR}" != "/tmp/theyos-engine-dist" ]; then
        return 0
    fi

    local fetch_script="${SRCROOT}/../scripts/fetch-engine.sh"
    if [ ! -x "${fetch_script}" ]; then
        return 0
    fi

    echo "→ theyos-engine cache is missing helpers; refreshing default cache."
    THEYOS_BUILD_DIR="${THEYOS_BUILD_DIR}" "${fetch_script}"
}

mkdir -p "${LAUNCH_AGENTS_DIR}"
cp "${LAUNCH_AGENT_SRC}" "${LAUNCH_AGENT_DEST}"
echo "Embedded LaunchAgent plist → ${LAUNCH_AGENT_DEST}"

if [ ! -f "${ENGINE_SRC}" ] && [ -f "${LOCAL_SERVER_SRC}" ]; then
    ENGINE_SRC="${LOCAL_SERVER_SRC}"
fi

if [ ! -f "${ENGINE_SRC}" ]; then
    if [ "${CONFIGURATION:-}" = "Release" ]; then
        echo "error: theyos-engine not found at ${ENGINE_SRC}" >&2
        echo "       Run scripts/fetch-engine.sh or set THEYOS_BUILD_DIR to a local build before archiving." >&2
        exit 1
    fi
    echo "theyos-engine not found at ${ENGINE_SRC}; skipping embed for ${CONFIGURATION:-Debug} build."
    echo "Run scripts/fetch-engine.sh or set THEYOS_BUILD_DIR to a local build before testing onboarding."
    exit 0
fi

if ! has_required_helpers; then
    if [ "${CONFIGURATION:-}" != "Release" ]; then
        echo "Engine helpers unavailable; skipping engine embed for ${CONFIGURATION:-Debug} build."
        echo "Set THEYOS_BUILD_DIR to a local theyOS release build before testing onboarding."
        exit 0
    fi

    refresh_default_cache_if_needed
fi

if ! has_required_helpers; then
    for helper in "${REQUIRED_HELPERS[@]}"; do
        if [ ! -f "${THEYOS_BUILD_DIR}/${helper}" ]; then
            echo "error: required engine helper missing: ${THEYOS_BUILD_DIR}/${helper}" >&2
            echo "       Soyeht.app needs ${helper} so the local engine can start." >&2
            exit 1
        fi
    done
fi

mkdir -p "${HELPERS_DIR}"
cp "${ENGINE_SRC}" "${ENGINE_DEST}"
chmod +x "${ENGINE_DEST}"

for helper in "${REQUIRED_HELPERS[@]}"; do
    cp "${THEYOS_BUILD_DIR}/${helper}" "${HELPERS_DIR}/${helper}"
    chmod +x "${HELPERS_DIR}/${helper}"
done

sign_helper() {
    local helper_path="$1"
    local entitlements_path="${SRCROOT}/SoyehtMac/SoyehtEngine.entitlements"
    if [ "$(basename "${helper_path}")" = "vmrunner_macos_ipc" ]; then
        entitlements_path="${SRCROOT}/SoyehtMac/SoyehtVMRunner.entitlements"
    fi
    if [ "${CODE_SIGN_IDENTITY}" != "-" ] && [ -n "${CODE_SIGN_IDENTITY}" ]; then
        codesign \
            --force \
            --sign "${CODE_SIGN_IDENTITY}" \
            --timestamp \
            --options runtime \
            --entitlements "${entitlements_path}" \
            "${helper_path}"
        echo "Signed $(basename "${helper_path}") with ${CODE_SIGN_IDENTITY} and $(basename "${entitlements_path}")"
    fi
}

sign_helper "${ENGINE_DEST}"
for helper in "${REQUIRED_HELPERS[@]}"; do
    sign_helper "${HELPERS_DIR}/${helper}"
done

if [ "${CODE_SIGN_IDENTITY}" = "-" ] || [ -z "${CODE_SIGN_IDENTITY}" ]; then
    echo "Skipping helper codesign (ad-hoc / development build)"
fi

echo "Embedded engine helpers → ${HELPERS_DIR}"
