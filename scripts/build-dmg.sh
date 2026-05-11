#!/bin/bash
# T141 — Produce a notarized+stapled Soyeht.dmg from an Xcode archive.
# Called by the release CI workflow on every tag push.
#
# Prerequisites (set via environment or .env.release):
#   DEVELOPER_ID_APPLICATION  — "Developer ID Application: Name (TEAMID)"
#   NOTARIZATION_PROFILE      — keychain notarytool profile name
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
EXPORT_PATH="${REPO_ROOT}/Products/export"
APP_NAME="Soyeht"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${DMG_OUTPUT_DIR}/${DMG_NAME}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')}"
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-}"
TEAM_ID="${TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
TEMP_EXPORT_OPTIONS=""
STAGING_DIR=""
SCRATCH_DIR=""

cleanup() {
    [[ -n "${TEMP_EXPORT_OPTIONS}" ]] && rm -f "${TEMP_EXPORT_OPTIONS}"
    [[ -n "${STAGING_DIR}" ]] && rm -rf "${STAGING_DIR}"
    [[ -n "${SCRATCH_DIR}" ]] && rm -rf "${SCRATCH_DIR}"
}

trap cleanup EXIT

# ── Guards ────────────────────────────────────────────────────────────────────

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

# ── Step 1: Export .app from archive ─────────────────────────────────────────

echo "→ Exporting .app from archive..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${TEMP_EXPORT_OPTIONS}" \
    -exportPath "${EXPORT_PATH}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: export did not produce ${APP_PATH}" >&2
    exit 1
fi

ENGINE_AGENT="${APP_PATH}/Contents/Library/LaunchAgents/com.soyeht.engine.plist"
for helper in theyos-engine vmrunner_macos_ipc store-ipc terminal-ipc theyos-ssh; do
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

# ── Step 2: Verify signing ────────────────────────────────────────────────────

echo "→ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
if ! spctl --assess --verbose=4 --type exec "${APP_PATH}"; then
    echo "warning: pre-notarization Gatekeeper assessment failed; continuing to DMG creation." >&2
fi

# ── Step 3: Build DMG via hdiutil ────────────────────────────────────────────

echo "→ Creating DMG..."
STAGING_DIR="$(mktemp -d)"
SCRATCH_DIR="$(mktemp -d)"

cp -R "${APP_PATH}" "${STAGING_DIR}/"

# ── Step 3a: Bundle APNs key into staged app ─────────────────────────────────
# The Xcode build phase (bundle-apns-key.sh) is the canonical path; this is
# a fallback for archives produced without it (e.g. CI without the key).
# Modifying the bundle requires a re-sign to keep Gatekeeper happy.

APNS_KEY_SOURCE="${APNS_KEY_SOURCE:-${HOME}/.soyeht/apns.p8}"
STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"
APNS_KEY_DEST="${STAGED_APP}/Contents/Resources/apns.p8"

if [[ -f "${APNS_KEY_DEST}" ]]; then
    echo "→ APNs key already present in export (build phase ran); skipping."
elif [[ -f "${APNS_KEY_SOURCE}" ]]; then
    mkdir -p "${STAGED_APP}/Contents/Resources"
    cp "${APNS_KEY_SOURCE}" "${APNS_KEY_DEST}"
    chmod 0600 "${APNS_KEY_DEST}"
    echo "✓ APNs key bundled at ${APNS_KEY_DEST}"
    # Re-sign the outer .app after adding a resource. Do NOT use --deep: nested
    # helpers were already signed by embed-engine.sh with their own entitlements
    # (including Virtualization for vmrunner_macos_ipc); --deep would strip or
    # overwrite that scope. Apple inside-out signing: helpers first, outer last.
    echo "→ Re-signing staged app (outer only) after adding resource..."
    codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
        --timestamp \
        --options runtime \
        --entitlements "${REPO_ROOT}/TerminalApp/SoyehtMac/SoyehtMac.entitlements" \
        "${STAGED_APP}"
else
    echo "warning: APNs key not found at ${APNS_KEY_SOURCE} — Caso B push will degrade to Bonjour-only" >&2
fi

# Applications symlink for drag-to-install UX.
ln -s /Applications "${STAGING_DIR}/Applications"

# rw.dmg goes to SCRATCH_DIR (separate from -srcfolder) to avoid ENOSPC:
# hdiutil sizes the image from the source dir before writing — output inside
# the source dir causes the image to overflow as rw.dmg grows.
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDRW \
    "${SCRATCH_DIR}/rw.dmg"

# Convert to compressed read-only directly into the output dir.
hdiutil convert "${SCRATCH_DIR}/rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=6 \
    -o "${DMG_PATH}"

# ── Step 4: Sign the DMG ──────────────────────────────────────────────────────

echo "→ Signing DMG..."
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
    --timestamp \
    "${DMG_PATH}"

# ── Step 5: Notarize ─────────────────────────────────────────────────────────

if [[ -z "${NOTARIZATION_PROFILE}" ]]; then
    echo "warning: NOTARIZATION_PROFILE not set; skipping notarization." >&2
    echo "→ DMG produced (not notarized): ${DMG_PATH}"
    exit 0
fi

echo "→ Submitting for notarization (profile: ${NOTARIZATION_PROFILE})..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARIZATION_PROFILE}" \
    --wait

# ── Step 6: Staple ───────────────────────────────────────────────────────────

echo "→ Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

# ── Step 7: Final verification ────────────────────────────────────────────────

echo "→ Verifying notarized DMG..."
spctl --assess --verbose=4 --type open --context context:primary-signature "${DMG_PATH}"

echo ""
echo "✓ Done: ${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"
