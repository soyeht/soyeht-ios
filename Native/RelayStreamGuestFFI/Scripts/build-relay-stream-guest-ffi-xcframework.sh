#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${RELAY_STREAM_GUEST_FFI_PROFILE:-debug}"
MIN_VERSION="${RELAY_STREAM_GUEST_FFI_IOS_MIN_VERSION:-16.0}"
MACOS_MIN_VERSION="${RELAY_STREAM_GUEST_FFI_MACOS_MIN_VERSION:-13.0}"
BUILT_AT="${RELAY_STREAM_GUEST_FFI_BUILT_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
FRAMEWORK="$ROOT/RelayStreamGuestFFI.xcframework"
CRATE="$ROOT"
LIB_NAME="librelay_stream_guest_ffi.a"
SOURCE_REV="c81144ba9ac98c0b19912c51765886b227ba30f5"

"$ROOT/Scripts/prepare-household-rs-source.sh"

profile_dir() {
  if [[ "$PROFILE" == "release" ]]; then
    printf 'release'
  else
    printf 'debug'
  fi
}

build_target() {
  local target="$1" sdk="$2" clang_target="$3" min_flag="$4"
  local dev_dir toolchain_bin sdkroot
  dev_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
  toolchain_bin="$dev_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local args=(build --target "$target")
  [[ "$PROFILE" == "release" ]] && args+=(--release)
  ( cd "$CRATE" && env \
      SDKROOT="$sdkroot" \
      IPHONEOS_DEPLOYMENT_TARGET="$MIN_VERSION" \
      CC="$toolchain_bin/clang" \
      CXX="$toolchain_bin/clang++" \
      AR="$toolchain_bin/ar" \
      RANLIB="$toolchain_bin/ranlib" \
      CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$toolchain_bin/clang" \
      CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER="$toolchain_bin/clang" \
      RUSTFLAGS="-C linker=$toolchain_bin/clang -C link-arg=-target -C link-arg=$clang_target -C link-arg=$min_flag=$MIN_VERSION" \
      cargo "${args[@]}" )
}

build_host() {
  local dev_dir toolchain_bin sdkroot args
  dev_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
  toolchain_bin="$dev_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
  sdkroot="$(xcrun --sdk macosx --show-sdk-path)"
  args=(build)
  [[ "$PROFILE" == "release" ]] && args+=(--release)
  ( cd "$CRATE" && env \
      SDKROOT="$sdkroot" \
      MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
      CC="$toolchain_bin/clang" \
      CXX="$toolchain_bin/clang++" \
      AR="$toolchain_bin/ar" \
      RANLIB="$toolchain_bin/ranlib" \
      RUSTFLAGS="-C link-arg=-mmacosx-version-min=$MACOS_MIN_VERSION" \
      cargo "${args[@]}" )
}

target_lib() {
  printf '%s/target/%s/%s/%s\n' "$ROOT" "$1" "$(profile_dir)" "$LIB_NAME"
}

host_lib() {
  printf '%s/target/%s/%s\n' "$ROOT" "$(profile_dir)" "$LIB_NAME"
}

echo "[relay-stream-guest-ffi] building Rust static libs (${PROFILE})"
build_target aarch64-apple-ios-sim iphonesimulator "arm64-apple-ios${MIN_VERSION}-simulator" "-mios-simulator-version-min"
build_target aarch64-apple-ios iphoneos "arm64-apple-ios${MIN_VERSION}" "-miphoneos-version-min"
build_host

echo "[relay-stream-guest-ffi] refreshing UniFFI bindings"
UNIFFI_MANIFEST="${UNIFFI_MANIFEST:-}"
if [[ -z "$UNIFFI_MANIFEST" ]]; then
  for candidate in "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/uniffi-0.31.2/Cargo.toml; do
    if [[ -f "$candidate" ]]; then
      UNIFFI_MANIFEST="$candidate"
      break
    fi
  done
fi
if [[ -z "$UNIFFI_MANIFEST" || ! -f "$UNIFFI_MANIFEST" ]]; then
  echo "error: UniFFI 0.31.2 manifest not found; set UNIFFI_MANIFEST" >&2
  exit 1
fi
( cd "$CRATE" && \
  cargo run --manifest-path "$UNIFFI_MANIFEST" \
    --features cli \
    --bin uniffi-bindgen -- \
    generate --library --language swift --out-dir Generated "target/$(profile_dir)/librelay_stream_guest_ffi.dylib" )
"$ROOT/Scripts/postprocess-uniffi-swift.sh" "$ROOT/Generated/relay_stream_guest_ffi.swift"

echo "[relay-stream-guest-ffi] refreshing C header target"
mkdir -p "$ROOT/Sources/relay_stream_guest_ffiFFI/include"
perl -pi -e 's/[[:blank:]]+$//' "$ROOT/Generated/relay_stream_guest_ffiFFI.h"
perl -0pi -e 's/\n+\z/\n/' "$ROOT/Generated/relay_stream_guest_ffiFFI.h"
cp "$ROOT/Generated/relay_stream_guest_ffiFFI.h" "$ROOT/Sources/relay_stream_guest_ffiFFI/include/"
cp "$ROOT/Generated/relay_stream_guest_ffiFFI.modulemap" "$ROOT/Sources/relay_stream_guest_ffiFFI/include/module.modulemap"

echo "[relay-stream-guest-ffi] assembling $FRAMEWORK"
rm -rf "$FRAMEWORK"
xcodebuild -create-xcframework \
  -library "$(target_lib aarch64-apple-ios-sim)" \
  -library "$(target_lib aarch64-apple-ios)" \
  -library "$(host_lib)" \
  -output "$FRAMEWORK"

ios_sha="$(shasum -a 256 "$(target_lib aarch64-apple-ios)" | awk '{print $1}')"
sim_sha="$(shasum -a 256 "$(target_lib aarch64-apple-ios-sim)" | awk '{print $1}')"
host_sha="$(shasum -a 256 "$(host_lib)" | awk '{print $1}')"

# PROVENANCE OF THE CRATE'S OWN SOURCE.
#
# `source_rev` above pins the VENDORED theyos household-rs and says nothing
# about THIS repository, which owns the crate, the generated bindings and this
# script. An artifact stamped only with the vendor rev looks clean while its own
# Rust source is uncommitted, so the two producers are recorded separately.
#
# ORDER IS LOAD-BEARING: measured HERE, after the bindings were regenerated and
# copied and after the framework was assembled, and immediately before the
# manifest is written. Measuring earlier would let a generated binding that
# diverges from the commit be stamped clean.
#
# Deliberately NOT env-overridable: every value below comes from Git, so no
# caller can present a dirty tree as clean. Missing Git, or a directory outside
# a worktree, fails the build rather than emitting unattested provenance.
#
# `.vendor/`, `/target/`, `/.build/` and the `.xcframework` output are all
# covered by this crate's .gitignore, so porcelain does not see the build's own
# byproducts. `Generated/` and `Sources/` ARE tracked and therefore DO count.
FFI_SOURCE_REPO="https://github.com/soyeht/soyeht-ios.git"
command -v git >/dev/null 2>&1 || {
  echo "error: git is required to stamp ffi_source_rev" >&2
  exit 1
}
FFI_TOPLEVEL="$(git -C "$ROOT" rev-parse --show-toplevel)" || {
  echo "error: not inside a Git worktree; refusing to stamp provenance" >&2
  exit 1
}
FFI_SOURCE_REV="$(git -C "$FFI_TOPLEVEL" rev-parse HEAD)" || {
  echo "error: cannot resolve HEAD; refusing to stamp provenance" >&2
  exit 1
}
# `--untracked-files=all` so a new unstaged file counts; `--ignore-submodules=none`
# so a dirty submodule counts too.
if [[ -n "$(git -C "$FFI_TOPLEVEL" status --porcelain --untracked-files=all --ignore-submodules=none)" ]]; then
  FFI_SOURCE_REV="${FFI_SOURCE_REV}-dirty"
fi

cat > "$FRAMEWORK/buildinfo.json" <<JSON
{
  "source_repo": "https://github.com/soyeht/theyos",
  "source_rev": "$SOURCE_REV",
  "ffi_source_repo": "$FFI_SOURCE_REPO",
  "ffi_source_rev": "$FFI_SOURCE_REV",
  "built_at": "$BUILT_AT",
  "profile": "$PROFILE",
  "min_ios_version": "$MIN_VERSION",
  "min_macos_version": "$MACOS_MIN_VERSION",
  "targets": ["aarch64-apple-ios", "aarch64-apple-ios-sim", "host"],
  "lib_sha256": {
    "aarch64-apple-ios": "$ios_sha",
    "aarch64-apple-ios-sim": "$sim_sha",
    "host": "$host_sha"
  }
}
JSON

echo "[relay-stream-guest-ffi] done"
