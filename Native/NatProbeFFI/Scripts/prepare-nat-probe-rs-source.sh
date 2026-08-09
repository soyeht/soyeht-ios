#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPO="https://github.com/soyeht/theyos.git"
# MERGED PIN: theyos PR #454 landed on main as d8ba4f22f507203835b89fd70a33ffa13e169ac7. Pinned to that
# merge commit rather than the pre-merge branch tip, which is gone now
# that the branch merged and isn't guaranteed fetchable from a fresh clone.
SOURCE_REV="d8ba4f22f507203835b89fd70a33ffa13e169ac7"
VENDOR_PARENT="$ROOT/.vendor"
VENDOR_ROOT="$VENDOR_PARENT/theyos"
STAMP="$VENDOR_ROOT/.nat-probe-source"
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

git clone --quiet "$SOURCE_REPO" "$TEMP_ROOT"
git -C "$TEMP_ROOT" fetch --quiet origin main
git -C "$TEMP_ROOT" checkout --quiet --detach "$SOURCE_REV"
printf '%s\n' "$EXPECTED_STAMP" > "$TEMP_ROOT/.nat-probe-source"

rm -rf "$VENDOR_ROOT"
mv "$TEMP_ROOT" "$VENDOR_ROOT"
trap - EXIT
