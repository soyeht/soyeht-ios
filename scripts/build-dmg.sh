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

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${REPO_ROOT}/Products/Soyeht.xcarchive}"
DMG_OUTPUT_DIR="${DMG_OUTPUT_DIR:-${REPO_ROOT}/Products/dmg}"
EXPORT_OPTIONS_PLIST="${SCRIPT_DIR}/ExportOptions.plist"
EXPORT_PATH="${REPO_ROOT}/Products/export"
APP_NAME="Soyeht"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${DMG_OUTPUT_DIR}/${DMG_NAME}"

# ── Guards ────────────────────────────────────────────────────────────────────

if [[ -z "${DEVELOPER_ID_APPLICATION}" ]]; then
    echo "error: DEVELOPER_ID_APPLICATION not set. Export from .env.release or environment." >&2
    exit 1
fi

if [[ ! -d "${ARCHIVE_PATH}" ]]; then
    echo "error: archive not found at ${ARCHIVE_PATH}" >&2
    exit 1
fi

mkdir -p "${DMG_OUTPUT_DIR}"
mkdir -p "${EXPORT_PATH}"

# ── Step 1: Export .app from archive ─────────────────────────────────────────

echo "→ Exporting .app from archive..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    -exportPath "${EXPORT_PATH}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: export did not produce ${APP_PATH}" >&2
    exit 1
fi

# ── Step 2: Verify signing ────────────────────────────────────────────────────

echo "→ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --verbose=4 --type exec "${APP_PATH}"

# ── Step 3: Build DMG via hdiutil ────────────────────────────────────────────

echo "→ Creating DMG..."
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

cp -R "${APP_PATH}" "${STAGING_DIR}/"

# Applications symlink for drag-to-install UX.
ln -s /Applications "${STAGING_DIR}/Applications"

TEMP_DMG="${STAGING_DIR}/${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}/${APP_NAME}.app" \
    -ov \
    -format UDRW \
    "${STAGING_DIR}/rw.dmg"

# Convert to compressed read-only.
hdiutil convert "${STAGING_DIR}/rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=6 \
    -o "${TEMP_DMG}"

cp "${TEMP_DMG}" "${DMG_PATH}"

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
