#!/bin/bash
# T141 — Produce a notarized+stapled Soyeht.dmg from an Xcode archive.
# Called by the release CI workflow on every tag push.
#
# Prerequisites (set via environment or .env.release):
#   DEVELOPER_ID_APPLICATION  — "Developer ID Application: Name (TEAMID)"
#   NOTARIZATION_PROFILE      — keychain notarytool profile name
#   APPLE_NOTARY_KEY_PATH     — App Store Connect API private key for CI notarization
#   APPLE_NOTARY_KEY_ID       — App Store Connect API key ID
#   APPLE_NOTARY_ISSUER_ID    — App Store Connect API issuer ID
#   APPLE_ID                  — legacy Apple ID email fallback for CI notarization
#   APPLE_ID_APP_PASSWORD     — legacy app-specific Apple ID password fallback
#   TEAM_ID                   — Apple Developer Team ID
#   ARCHIVE_PATH              — path to .xcarchive (default: Products/Soyeht.xcarchive)
#   DMG_OUTPUT_DIR            — destination directory (default: Products/dmg)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env.release if present (gitignored; holds signing identity + profile).
ENV_FILE="${REPO_ROOT}/.env.release"
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

ARCHIVE_PATH="${ARCHIVE_PATH:-${REPO_ROOT}/Products/Soyeht.xcarchive}"
DMG_OUTPUT_DIR="${DMG_OUTPUT_DIR:-${REPO_ROOT}/Products/dmg}"
EXPORT_OPTIONS_TEMPLATE="${SCRIPT_DIR}/ExportOptions.plist"
EXPORT_PATH="${EXPORT_PATH:-${REPO_ROOT}/Products/export}"
APP_NAME="Soyeht"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${DMG_OUTPUT_DIR}/${DMG_NAME}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-}"
TEAM_ID="${TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
APPLE_NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
APPLE_NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_ID_APP_PASSWORD="${APPLE_ID_APP_PASSWORD:-}"
TEMP_EXPORT_OPTIONS=""
STAGING_DIR=""
SCRATCH_DIR=""
DMG_MOUNT_DIR=""
DMG_MOUNTED=0

cleanup() {
    if [[ "${DMG_MOUNTED}" == "1" && -n "${DMG_MOUNT_DIR}" ]]; then
        hdiutil detach "${DMG_MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
    [[ -n "${DMG_MOUNT_DIR}" ]] && rmdir "${DMG_MOUNT_DIR}" >/dev/null 2>&1 || true
    [[ -n "${TEMP_EXPORT_OPTIONS}" ]] && rm -f "${TEMP_EXPORT_OPTIONS}"
    [[ -n "${STAGING_DIR}" ]] && rm -rf "${STAGING_DIR}"
    [[ -n "${SCRATCH_DIR}" ]] && rm -rf "${SCRATCH_DIR}"
}

trap cleanup EXIT

scan_product_root() {
    local product_root="$1"
    python3 "${REPO_ROOT}/scripts/ci/check-governed-macos-release.py" \
        --scan-product "${product_root}"
}

scan_dmg_contents() {
    local dmg_path="$1"
    DMG_MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-dmg-scan.XXXXXX")"
    hdiutil attach \
        -readonly \
        -nobrowse \
        -mountpoint "${DMG_MOUNT_DIR}" \
        "${dmg_path}" >/dev/null
    DMG_MOUNTED=1
    scan_product_root "${DMG_MOUNT_DIR}"
    hdiutil detach "${DMG_MOUNT_DIR}" >/dev/null
    DMG_MOUNTED=0
    rmdir "${DMG_MOUNT_DIR}"
    DMG_MOUNT_DIR=""
}

sign_outer_app() {
    local app_path="$1"
    codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
        --timestamp \
        --options runtime \
        --entitlements "${REPO_ROOT}/TerminalApp/SoyehtMac/SoyehtMac.entitlements" \
        "${app_path}"
}

sign_embedded_sparkle() {
    local sparkle_framework="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
    local sparkle_current="${sparkle_framework}/Versions/Current"

    [[ -d "${sparkle_framework}" ]] || return 0

    local components=(
        "${sparkle_current}/XPCServices/Downloader.xpc"
        "${sparkle_current}/XPCServices/Installer.xpc"
        "${sparkle_current}/Updater.app"
        "${sparkle_current}/Autoupdate"
        "${sparkle_framework}"
    )

    echo "→ Re-signing embedded Sparkle components..."
    for component in "${components[@]}"; do
        [[ -e "${component}" ]] || continue
        codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
            --timestamp \
            --options runtime \
            "${component}"
    done
}

sign_engine_helpers() {
    local app_path="$1"
    local helpers_dir="${app_path}/Contents/Helpers"
    local engine_entitlements="${REPO_ROOT}/TerminalApp/SoyehtMac/SoyehtEngine.entitlements"
    local vmrunner_entitlements="${REPO_ROOT}/TerminalApp/SoyehtMac/SoyehtVMRunner.entitlements"
    local helper helper_path entitlements_path

    echo "→ Re-signing embedded engine helpers..."
    for helper in theyos-engine vmrunner_macos_ipc store-ipc terminal-ipc theyos-ssh theyos-provision-inject; do
        helper_path="${helpers_dir}/${helper}"
        if [[ ! -x "${helper_path}" ]]; then
            echo "error: exported app is missing executable ${helper_path}" >&2
            echo "       Run scripts/fetch-engine.sh before archiving, then archive again." >&2
            exit 1
        fi

        entitlements_path="${engine_entitlements}"
        if [[ "${helper}" == "vmrunner_macos_ipc" ]]; then
            entitlements_path="${vmrunner_entitlements}"
        fi

        codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
            --timestamp \
            --options runtime \
            --entitlements "${entitlements_path}" \
            "${helper_path}"
    done
}

# ── Guards ────────────────────────────────────────────────────────────────────

# A provider signing key is server-side authority. A public client build must
# fail closed if a legacy local/CI variable tries to reintroduce that authority.
for forbidden_provider_variable in APNS_KEY_SOURCE APNS_KEY_PATH SOYEHT_APNS_P8_BASE64; do
    if [[ -n "${!forbidden_provider_variable:-}" ]]; then
        echo "error: ${forbidden_provider_variable} must not be supplied to a public client build." >&2
        exit 1
    fi
done

if [[ -z "${DEVELOPER_ID_APPLICATION}" ]]; then
    echo "error: DEVELOPER_ID_APPLICATION not set. Export from .env.release or environment." >&2
    exit 1
fi

if [[ ! -d "${ARCHIVE_PATH}" ]]; then
    echo "error: archive not found at ${ARCHIVE_PATH}" >&2
    exit 1
fi

if [[ -z "${TEAM_ID}" ]]; then
    TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' "${ARCHIVE_PATH}/Info.plist" 2>/dev/null || true)"
fi

if [[ -z "${TEAM_ID}" && "${DEVELOPER_ID_APPLICATION}" =~ \(([A-Z0-9]{10})\)$ ]]; then
    TEAM_ID="${BASH_REMATCH[1]}"
fi

if [[ -z "${TEAM_ID}" ]]; then
    echo "error: TEAM_ID/DEVELOPMENT_TEAM not set and could not be inferred from archive or signing identity." >&2
    exit 1
fi

mkdir -p "${DMG_OUTPUT_DIR}"
rm -rf "${EXPORT_PATH}"
mkdir -p "${EXPORT_PATH}"

TEMP_EXPORT_OPTIONS="$(mktemp "${TMPDIR:-/tmp}/soyeht-export-options.XXXXXX.plist")"
sed "s|\\\$(DEVELOPMENT_TEAM)|${TEAM_ID}|g" "${EXPORT_OPTIONS_TEMPLATE}" > "${TEMP_EXPORT_OPTIONS}"

# ── Step 1: Extract .app from archive ────────────────────────────────────────

if [[ -d "${ARCHIVED_APP_PATH}" ]]; then
    echo "→ Copying .app from archive..."
    ditto "${ARCHIVED_APP_PATH}" "${APP_PATH}"
else
    echo "→ Exporting .app from archive..."
    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportOptionsPlist "${TEMP_EXPORT_OPTIONS}" \
        -exportPath "${EXPORT_PATH}"
fi

if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: export did not produce ${APP_PATH}" >&2
    exit 1
fi

ENGINE_AGENT="${APP_PATH}/Contents/Library/LaunchAgents/com.soyeht.engine.plist"
for helper in theyos-engine vmrunner_macos_ipc store-ipc terminal-ipc theyos-ssh theyos-provision-inject; do
    helper_path="${APP_PATH}/Contents/Helpers/${helper}"
    if [[ ! -x "${helper_path}" ]]; then
        echo "error: exported app is missing executable ${helper_path}" >&2
        echo "       Run scripts/fetch-engine.sh before archiving, then archive again." >&2
        exit 1
    fi
done
if [[ ! -f "${ENGINE_AGENT}" ]]; then
    echo "error: exported app is missing ${ENGINE_AGENT}" >&2
    echo "       The Embed Engine Binary build phase did not copy the SMAppService plist." >&2
    exit 1
fi

sign_embedded_sparkle
sign_engine_helpers "${APP_PATH}"
sign_outer_app "${APP_PATH}"

# ── Step 2: Verify signing ────────────────────────────────────────────────────

echo "→ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
if ! spctl --assess --verbose=4 --type exec "${APP_PATH}"; then
    echo "Pre-notarization Gatekeeper assessment failed; continuing to DMG creation." >&2
fi

# ── Step 3: Build DMG via hdiutil ────────────────────────────────────────────

echo "→ Creating DMG..."
STAGING_DIR="$(mktemp -d)"
SCRATCH_DIR="$(mktemp -d)"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"
COMPANION_APP="${STAGING_DIR}/Uninstall ${APP_NAME}.app"

echo "→ Creating graphical uninstaller companion..."
ditto "${STAGED_APP}" "${COMPANION_APP}"
MAIN_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${STAGED_APP}/Contents/Info.plist")"
/usr/bin/plutil -replace CFBundleName -string "Uninstall ${APP_NAME}" "${COMPANION_APP}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "Uninstall ${APP_NAME}" "${COMPANION_APP}/Contents/Info.plist"
# Keep the main app bundle identifier so the recovery uninstaller can access
# Soyeht's Data Protection Keychain rows, which are scoped to that app identity.
/usr/bin/plutil -replace CFBundleIdentifier -string "${MAIN_BUNDLE_ID}" "${COMPANION_APP}/Contents/Info.plist"
/usr/bin/plutil -replace SoyehtUninstallerMode -bool YES "${COMPANION_APP}/Contents/Info.plist"
/usr/bin/plutil -remove CFBundleURLTypes "${COMPANION_APP}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/bin/plutil -remove SUFeedURL "${COMPANION_APP}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/bin/plutil -remove SUPublicEDKey "${COMPANION_APP}/Contents/Info.plist" >/dev/null 2>&1 || true
sign_outer_app "${COMPANION_APP}"
codesign --verify --deep --strict --verbose=2 "${COMPANION_APP}"

# Applications symlink for drag-to-install UX.
ln -s /Applications "${STAGING_DIR}/Applications"

echo "→ Verifying staged public product contains no provider private key..."
scan_product_root "${STAGING_DIR}"

# rw.dmg goes to SCRATCH_DIR (separate from -srcfolder) to avoid ENOSPC:
# hdiutil sizes the image from the source dir before writing — output inside
# the source dir causes the image to overflow as rw.dmg grows.
# NOTE: `-srcfolder` fails on this machine with "Operation not permitted" the
# moment the staging dir holds two app bundles — macOS App Management protects
# the second one as hdiutil copies it. Building a blank image and copying into
# it ourselves does the same job and is not blocked.
STAGING_MB=$(( $(du -sm "${STAGING_DIR}" | cut -f1) + 120 ))
hdiutil create \
    -volname "${APP_NAME}" \
    -size "${STAGING_MB}m" \
    -fs HFS+ \
    -ov \
    "${SCRATCH_DIR}/rw.dmg"
hdiutil attach "${SCRATCH_DIR}/rw.dmg" -nobrowse -mountpoint "${SCRATCH_DIR}/mnt"
ditto "${STAGING_DIR}/${APP_NAME}.app" "${SCRATCH_DIR}/mnt/${APP_NAME}.app"
ditto "${COMPANION_APP}" "${SCRATCH_DIR}/mnt/Uninstall ${APP_NAME}.app"
ln -s /Applications "${SCRATCH_DIR}/mnt/Applications"
hdiutil detach "${SCRATCH_DIR}/mnt"

# Convert to compressed read-only directly into the output dir.
rm -f "${DMG_PATH}"
hdiutil convert "${SCRATCH_DIR}/rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=6 \
    -ov \
    -o "${DMG_PATH}"

# ── Step 4: Sign the DMG ──────────────────────────────────────────────────────

echo "→ Signing DMG..."
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
    --timestamp \
    "${DMG_PATH}"

echo "→ Verifying signed DMG contains no provider private key before notarization..."
scan_dmg_contents "${DMG_PATH}"

# ── Step 5: Notarize ─────────────────────────────────────────────────────────

if [[ -n "${NOTARIZATION_PROFILE}" ]]; then
    echo "→ Submitting for notarization (profile: ${NOTARIZATION_PROFILE})..."
    NOTARY_OUTPUT="$(xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARIZATION_PROFILE}" \
        --wait \
        --output-format json)"
elif [[ -n "${APPLE_NOTARY_KEY_PATH}" && -n "${APPLE_NOTARY_KEY_ID}" && -n "${APPLE_NOTARY_ISSUER_ID}" ]]; then
    echo "→ Submitting for notarization (App Store Connect API key: ${APPLE_NOTARY_KEY_ID})..."
    NOTARY_OUTPUT="$(xcrun notarytool submit "${DMG_PATH}" \
        --key "${APPLE_NOTARY_KEY_PATH}" \
        --key-id "${APPLE_NOTARY_KEY_ID}" \
        --issuer "${APPLE_NOTARY_ISSUER_ID}" \
        --wait \
        --output-format json)"
elif [[ -n "${APPLE_ID}" && -n "${APPLE_ID_APP_PASSWORD}" && -n "${TEAM_ID}" ]]; then
    echo "→ Submitting for notarization (Apple ID credentials, team: ${TEAM_ID})..."
    NOTARY_OUTPUT="$(xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${TEAM_ID}" \
        --password "${APPLE_ID_APP_PASSWORD}" \
        --wait \
        --output-format json)"
else
    echo "No notarization credentials set; skipping notarization." >&2
    echo "Set NOTARIZATION_PROFILE, or APPLE_NOTARY_KEY_PATH/APPLE_NOTARY_KEY_ID/APPLE_NOTARY_ISSUER_ID." >&2
    echo "→ DMG produced (not notarized): ${DMG_PATH}"
    exit 0
fi

echo "${NOTARY_OUTPUT}"
NOTARY_STATUS="$(printf '%s' "${NOTARY_OUTPUT}" | plutil -extract status raw -o - - 2>/dev/null || true)"
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    echo "error: notarization did not finish as Accepted (status: ${NOTARY_STATUS:-unknown})." >&2
    exit 1
fi

# ── Step 6: Staple ───────────────────────────────────────────────────────────

echo "→ Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo "→ Verifying final stapled DMG contains no provider private key..."
scan_dmg_contents "${DMG_PATH}"

# ── Step 7: Final verification ────────────────────────────────────────────────

echo "→ Verifying notarized DMG..."
spctl --assess --verbose=4 --type open --context context:primary-signature "${DMG_PATH}"

echo ""
echo "✓ Done: ${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"
