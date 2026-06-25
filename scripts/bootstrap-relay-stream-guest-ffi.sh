#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFI_ROOT="$ROOT/Native/RelayStreamGuestFFI"
BUILD_SCRIPT="$FFI_ROOT/Scripts/build-relay-stream-guest-ffi-xcframework.sh"
FRAMEWORK="$FFI_ROOT/RelayStreamGuestFFI.xcframework"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: RelayStreamGuestFFI XCFramework must be built on macOS" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: Xcode command line tools are required" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: Rust cargo is required; install Rust with rustup" >&2
  exit 1
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required so the iOS Rust targets can be installed" >&2
  exit 1
fi

echo "[relay-stream-guest-ffi] ensuring Rust iOS targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

"$BUILD_SCRIPT"

if [[ ! -d "$FRAMEWORK" ]]; then
  echo "error: expected XCFramework was not produced at $FRAMEWORK" >&2
  exit 1
fi

echo "[relay-stream-guest-ffi] ready: $FRAMEWORK"
