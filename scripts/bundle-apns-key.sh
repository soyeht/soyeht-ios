#!/bin/bash
# Copies the APNs .p8 key into Soyeht.app/Contents/Resources/apns.p8
# so the theyos-engine can send push notifications (Caso B UX).
#
# Without the .p8 the engine logs apns.push.key_open_failed and falls back
# to Bonjour-only pairing — app still works but loses push notification UX.
#
# Prerequisites:
#   Generate AuthKey_*.p8 at developer.apple.com → Certificates, IDs & Profiles
#   → Keys → (+) → "Apple Push Notifications service (APNs)"
#
# Usage:
#   APNS_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8 scripts/bundle-apns-key.sh
#   # or drop the file at the default path:
#   cp ~/Downloads/AuthKey_*.p8 ~/Downloads/AuthKey_soyeht.p8
set -euo pipefail

APNS_KEY_PATH="${APNS_KEY_PATH:-${HOME}/Downloads/AuthKey_soyeht.p8}"
RESOURCES_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"
DEST="${RESOURCES_DIR}/apns.p8"

if [ ! -f "${APNS_KEY_PATH}" ]; then
    echo "warning: APNs key not found at ${APNS_KEY_PATH}"
    echo "         Caso B push notifications will degrade to Bonjour-only."
    echo "         Set APNS_KEY_PATH or copy your AuthKey_*.p8 to ${APNS_KEY_PATH}"
    exit 0
fi

mkdir -p "${RESOURCES_DIR}"
cp "${APNS_KEY_PATH}" "${DEST}"
chmod 600 "${DEST}"
echo "✓ APNs key bundled → ${DEST}"
