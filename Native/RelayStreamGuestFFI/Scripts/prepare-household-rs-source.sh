#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPO="https://github.com/soyeht/theyos.git"
SOURCE_REV="c81144ba9ac98c0b19912c51765886b227ba30f5"
VENDOR_PARENT="$ROOT/.vendor"
VENDOR_ROOT="$VENDOR_PARENT/theyos"
STAMP="$VENDOR_ROOT/.relay-stream-guest-source"
EXPECTED_STAMP="$SOURCE_REV"

if [[ -f "$STAMP" ]] && [[ "$(sed -n '1p' "$STAMP")" == "$EXPECTED_STAMP" ]]; then
  exit 0
fi

mkdir -p "$VENDOR_PARENT"
TEMP_ROOT="$(mktemp -d "$VENDOR_PARENT/theyos.prepare.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

git clone --quiet --no-checkout "$SOURCE_REPO" "$TEMP_ROOT"
git -C "$TEMP_ROOT" checkout --quiet --detach "$SOURCE_REV"
printf '%s\n' "$EXPECTED_STAMP" > "$TEMP_ROOT/.relay-stream-guest-source"

rm -rf "$VENDOR_ROOT"
mv "$TEMP_ROOT" "$VENDOR_ROOT"
trap - EXIT
