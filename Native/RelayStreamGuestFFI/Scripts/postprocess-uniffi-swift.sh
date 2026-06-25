#!/usr/bin/env bash
set -euo pipefail

swift_file="${1:-Generated/relay_stream_guest_ffi.swift}"
old_status="$(printf '%s%s' 'CALL_UNE' 'XPECTED_ERROR')"

perl -0pi -e "s/${old_status}/CALL_INTERNAL_ERROR/g" "$swift_file"
