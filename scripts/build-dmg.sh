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
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}" "${SCRATCH_DIR}"' EXIT

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
    # helpers (theyos-engine) were already signed by embed-engine.sh with their
    # own entitlements (SoyehtEngine.entitlements); --deep would strip or
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
