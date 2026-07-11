#!/bin/bash
# Hermetic mutation matrix for the repo-level iOS PRE-EFFECT crossing guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKER="${ROOT}/scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-owner-present-gate.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

MARKER_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_runtime_activation_v1.json"
ERROR_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
ERROR_VENDOR_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
PIN_REL="scripts/cross-repo-contract.sha"
AUTOMATION_BASELINE_REL="scripts/mobile-claw-vpn-owner-present-automation-baseline.tsv"
BINARY_BASELINE_REL="scripts/mobile-claw-vpn-owner-present-binary-baseline.tsv"
SEALED_PATHS=(
  "Packages/SoyehtCore/Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/MobileClawVPNDevE2EExecutionTupleV1.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalContextV2DTO.swift"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalV2DTO.swift"
)
REVIEWED_TEST_ONLY_PATHS=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_success_wire_v1.json"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/OwnerCert/owner_cert_auth.cbor"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNAPIClientTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryGuardTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryTestSupport.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentCancellationTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentSuccessWireTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerApprovalV2ClientTests.swift"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerApprovalV2CrossLanguageVectorTests.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/AppCommandRegistry.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/AppSupportDirectory.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ClawDrawerViewModel.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ConversationStore.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/DaemonPairMachineStageClient.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/InstalledClawsProvider.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/JoinExistingCapability.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacClawInstallDecision.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacGuestImageReadinessGate.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacGuestImageRecovery.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacQRCodeImageFactory.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MainMenu"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/Model"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ObservationTracker.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/PairingStore.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/PaneAttachRegistry.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSEnvironment.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSHealthProber.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSInstaller.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSUninstallPlan.swift"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/WorkspaceStore.swift"
)
SIGNAL_AUTOMATION_PATHS=(
  "docs/mobile-claw-vpn-dev-e2e-runbook.md"
  "scripts/check-cross-repo-fixtures.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  "scripts/mobile-claw-vpn-dev-e2e-owner-request.py"
  "scripts/mobile-claw-vpn-dev-e2e-runner.sh"
  "scripts/mobile-claw-vpn-dev-local-presence.swift"
  "scripts/sync-cross-repo-fixtures.sh"
  "scripts/test-cross-repo-fixture-guard.sh"
  "scripts/test-mobile-claw-vpn-dev-e2e-owner-request.sh"
  "scripts/test-mobile-claw-vpn-dev-e2e-runner.sh"
  "scripts/test-mobile-claw-vpn-dev-local-presence.sh"
  "scripts/test-mobile-claw-vpn-dev-local-presence.swift"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  ".github/workflows/contract-fixture-sync.yml"
  ".github/workflows/owner-present-pre-effect-gate.yml"
  ".github/workflows/owner-present-pre-effect-integrity.yml"
)
REVIEWED_BINARY_SAMPLE="Packages/SoyehtCore/Sources/SoyehtCore/Resources/Fonts/JetBrainsMono-Regular.ttf"
REVIEWED_EXTERNAL_SAMPLE="Packages/SoyehtCore/Package.swift"
SURFACES=(
  "core:Packages/SoyehtCore/Sources/SoyehtCore/API/CrossingProbe.swift"
  "top_bootstrap_shell:scripts/bootstrap-relay-stream-guest-ffi.sh"
  "top_build_dmg_shell:scripts/build-dmg.sh"
  "top_bundle_apns_shell:scripts/bundle-apns-key.sh"
  "top_embed_engine_shell:scripts/embed-engine.sh"
  "top_fetch_engine_shell:scripts/fetch-engine.sh"
  "top_regen_unicode_python:scripts/regen_unicode_width_data.py"
  "top_future_build_shell:scripts/future-shipping-build.sh"
  "top_export_options:scripts/ExportOptions.plist"
  "top_engine_digest:scripts/theyos-engine.sha256"
  "top_engine_version:scripts/theyos-engine.version"
  "macos_release_workflow:.github/workflows/macos-release.yml"
  "future_release_workflow:.github/workflows/future-release.yaml"
  "root_makefile:Makefile"
  "root_package_resolved:Package.resolved"
  "package_resolved:Packages/SoyehtCore/Package.resolved"
  "metal_shader:Sources/SwiftTerm/Apple/Metal/CrossingProbe.metal"
  "core_localization:Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings"
  "ios_storyboard:TerminalApp/Soyeht/Base.lproj/CrossingProbe.storyboard"
  "ios_scheme:TerminalApp/Soyeht.xcodeproj/xcshareddata/xcschemes/CrossingProbe.xcscheme"
  "ios_workspace:TerminalApp/Soyeht.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
  "ios_asset_json:TerminalApp/Soyeht/Assets.xcassets/CrossingProbe.imageset/Contents.json"
  "core_tests_suffix:Packages/SoyehtCore/Sources/SoyehtCore/API/MobileClawVPNOwnerPresentTests.swift"
  "core_test_support:Packages/SoyehtCore/Sources/SoyehtCore/TestSupport/MobileClawVPNOwnerPresentAdapter.swift"
  "core_snapshots_name:Packages/SoyehtCore/Sources/SoyehtCore/__Snapshots__/CrossingProbe.swift"
  "core_nested_tests:Packages/SoyehtCore/Sources/SoyehtCore/Tests/CrossingProbe.swift"
  "core_nested_swift_tests:Packages/SoyehtCore/Sources/SoyehtCore/SwiftTests/CrossingProbe.swift"
  "core_nested_soyeht_tests:Packages/SoyehtCore/Sources/SoyehtCore/SoyehtTests/CrossingProbe.swift"
  "core_nested_soyeht_mac_tests:Packages/SoyehtCore/Sources/SoyehtCore/SoyehtMacTests/CrossingProbe.swift"
  "core_nested_scripts:Packages/SoyehtCore/Sources/SoyehtCore/scripts/CrossingProbe.swift"
  "core_nested_benchmarks:Packages/SoyehtCore/Sources/SoyehtCore/Benchmarks/CrossingProbe.swift"
  "core_nested_qa:Packages/SoyehtCore/Sources/SoyehtCore/QA/CrossingProbe.swift"
  "root_nested_tests:Sources/Foo/Tests/CrossingProbe.swift"
  "root_test_prefix:TestsSupport/CrossingProbe.swift"
  "package_test_prefix:Packages/SoyehtCore/TestsSupport/CrossingProbe.swift"
  "ios_app:TerminalApp/Soyeht/Settings/CrossingProbe.swift"
  "terminal_test_prefix:TerminalApp/SoyehtTestsSupport/CrossingProbe.swift"
  "terminal_mac_test_prefix:TerminalApp/SoyehtMacTestsSupport/CrossingProbe.swift"
  "terminal_nested_tests:TerminalApp/Soyeht/Sources/Foo/SoyehtTests/CrossingProbe.swift"
  "terminal_nested_mac_tests:TerminalApp/SoyehtMac/Sources/Foo/SoyehtMacTests/CrossingProbe.swift"
  "terminal_nested_generic_tests:TerminalApp/Soyeht/Sources/Foo/Tests/CrossingProbe.swift"
  "terminal_nested_swift_tests:TerminalApp/Soyeht/Sources/Foo/SwiftTests/CrossingProbe.swift"
  "terminal_nested_scripts:TerminalApp/Soyeht/Sources/Foo/scripts/CrossingProbe.swift"
  "terminal_nested_benchmarks:TerminalApp/Soyeht/Sources/Foo/Benchmarks/CrossingProbe.swift"
  "terminal_nested_qa:TerminalApp/Soyeht/Sources/Foo/QA/CrossingProbe.swift"
  "mac_app:TerminalApp/SoyehtMac/CrossingProbe.swift"
  "notification_extension:TerminalApp/HouseCreatedNotificationService/CrossingProbe.swift"
  "live_activity_extension:TerminalApp/SoyehtLiveActivity/CrossingProbe.swift"
  "native_rust:Native/RelayStreamGuestFFI/src/crossing_probe.rs"
  "native_build_shell:Native/RelayStreamGuestFFI/Scripts/build-relay-stream-guest-ffi-xcframework.sh"
  "native_postprocess_shell:Native/RelayStreamGuestFFI/Scripts/postprocess-uniffi-swift.sh"
  "native_c:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.c"
  "native_cc:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.cc"
  "native_cpp:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.cpp"
  "native_cxx:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.cxx"
  "native_objc:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.m"
  "native_objcpp:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/crossing_probe.mm"
  "native_header:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/include/crossing_probe.h"
  "native_hh:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/include/crossing_probe.hh"
  "native_hpp:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/include/crossing_probe.hpp"
  "native_modulemap:Native/RelayStreamGuestFFI/Sources/relay_stream_guest_ffiFFI/include/crossing_probe.modulemap"
  "native_cargo:Native/RelayStreamGuestFFI/Cargo.toml"
  "native_cargo_lock:Native/RelayStreamGuestFFI/Cargo.lock"
  "native_udl:Native/RelayStreamGuestFFI/src/crossing_probe.udl"
  "native_toml:Native/RelayStreamGuestFFI/config/crossing_probe.toml"
  "native_test_prefix:Native/RelayStreamGuestFFI/TestsSupport/crossing_probe.rs"
  "native_swift_test_prefix:Native/RelayStreamGuestFFI/SwiftTestsSupport/CrossingProbe.swift"
  "native_nested_swift_tests:Native/RelayStreamGuestFFI/Sources/Foo/SwiftTests/CrossingProbe.rs"
  "native_nested_generic_tests:Native/RelayStreamGuestFFI/Sources/Foo/Tests/CrossingProbe.rs"
  "native_nested_soyeht_tests:Native/RelayStreamGuestFFI/Sources/Foo/SoyehtTests/CrossingProbe.rs"
  "native_nested_soyeht_mac_tests:Native/RelayStreamGuestFFI/Sources/Foo/SoyehtMacTests/CrossingProbe.rs"
  "native_nested_scripts:Native/RelayStreamGuestFFI/Sources/Foo/scripts/crossing_probe.rs"
  "native_nested_benchmarks:Native/RelayStreamGuestFFI/Sources/Foo/Benchmarks/crossing_probe.rs"
  "native_nested_qa:Native/RelayStreamGuestFFI/Sources/Foo/QA/crossing_probe.rs"
  "future_xcconfig:FutureExtension/Config/CrossingProbe.xcconfig"
  "future_pbxproj:FutureExtension/CrossingProbe.xcodeproj/project.pbxproj"
  "future_plist:FutureExtension/Resources/CrossingProbe.plist"
  "future_entitlements:FutureExtension/CrossingProbe.entitlements"
  "future_extension:FutureExtension/Sources/CrossingProbe.swift"
  "future_lowercase_generator:FutureExtension/scripts/generate"
  "future_uppercase_generator:FutureExtension/Scripts/generate"
  "future_strings:FutureExtension/Resources/CrossingProbe.strings"
  "future_stringsdict:FutureExtension/Resources/CrossingProbe.stringsdict"
  "future_swiftinterface:FutureExtension/Interfaces/CrossingProbe.swiftinterface"
  "future_cmake:FutureExtension/Native/CMakeLists.txt"
  "future_cmake_module:FutureExtension/Native/crossing_probe.cmake"
  "future_ruby_build:FutureExtension/fastlane/build.rb"
  "future_fastfile:FutureExtension/fastlane/Fastfile"
  "future_podfile:FutureExtension/Podfile"
  "future_storekit:FutureExtension/Resources/CrossingProbe.storekit"
  "future_kotlin:FutureExtension/Kotlin/CrossingProbe.kt"
  "future_gradle:FutureExtension/Kotlin/build.gradle.kts"
  $'filename_tab:FutureExtension/Sources/Crossing\tProbe.swift'
  $'filename_newline:FutureExtension/Sources/Crossing\nProbe.swift'
)
UPPERCASE_CASES=(
  "uppercase_symbol:Native/RelayStreamGuestFFI/src/uppercase_symbol.h"
  "uppercase_path:Native/RelayStreamGuestFFI/src/uppercase_path.rs"
)
BINARY_SURFACES=(
  "existing_xcframework:Native/RelayStreamGuestFFI/RelayStreamGuestFFI.xcframework/macos-arm64/RelayStreamGuestFFI"
  "future_xcframework:FutureExtension/Binaries/Future.xcframework/ios-arm64/Future"
  "future_framework:FutureExtension/Binaries/Future.framework/Future"
  "future_artifact_bundle:FutureExtension/Binaries/Future.artifactbundle/bin/Future"
  "future_app:FutureExtension/Binaries/Future.app/Contents/MacOS/Future"
  "future_appex:FutureExtension/Binaries/Future.appex/Future"
  "future_xpc:FutureExtension/Binaries/Future.xpc/Contents/MacOS/Future"
  "future_bundle:FutureExtension/Binaries/Future.bundle/Contents/MacOS/Future"
  "future_static_archive:FutureExtension/Binaries/libFuture.a"
  "future_object:FutureExtension/Binaries/Future.o"
  "future_dylib:FutureExtension/Binaries/libFuture.dylib"
  "future_so:FutureExtension/Binaries/libFuture.so"
)
MAGIC_SURFACES=(
  "magic_macho_thin:Native/RelayStreamGuestFFI/bin/transport:macho:100755"
  "magic_macho_fat:Native/RelayStreamGuestFFI/bin/universal:fat:100755"
  "magic_elf:Native/RelayStreamGuestFFI/bin/relay:elf:100755"
  "magic_ar:Native/RelayStreamGuestFFI/bin/archive:ar:100644"
  "magic_wasm:Native/RelayStreamGuestFFI/bin/module:wasm:100644"
  "magic_pe:Native/RelayStreamGuestFFI/bin/windows:pe:100644"
  "magic_bitcode:Native/RelayStreamGuestFFI/bin/llvm:bitcode:100644"
  "magic_unknown_opaque:Native/RelayStreamGuestFFI/bin/payload:opaque:100644"
)
NON_SHIPPING_AUTOMATION_PATHS=(
  "docs/mobile-claw-vpn-dev-e2e-runbook.md"
  "scripts/check-cross-repo-fixtures.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/check-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  "scripts/ci/lint-ui-resources.py"
  "scripts/dev-embedded-engine-smoke.sh"
  "scripts/dev-local-apple-attestation-capture.sh"
  "scripts/gen-claw-store-contract-constants.py"
  "scripts/mobile-claw-vpn-dev-e2e-env.sh"
  "scripts/mobile-claw-vpn-dev-e2e-owner-request.py"
  "scripts/mobile-claw-vpn-dev-e2e-owner-request.sh"
  "scripts/mobile-claw-vpn-dev-e2e-preflight.sh"
  "scripts/mobile-claw-vpn-dev-e2e-runner.sh"
  "scripts/mobile-claw-vpn-dev-local-presence.swift"
  "scripts/secure-upgrade-app-attest-capture.sh"
  "scripts/sync-cross-repo-fixtures.sh"
  "scripts/test-cross-repo-fixture-guard.sh"
  "scripts/test-mobile-claw-vpn-dev-e2e-owner-request.sh"
  "scripts/test-mobile-claw-vpn-dev-e2e-preflight.sh"
  "scripts/test-mobile-claw-vpn-dev-e2e-runner.sh"
  "scripts/test-mobile-claw-vpn-dev-local-presence.sh"
  "scripts/test-mobile-claw-vpn-dev-local-presence.swift"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect.sh"
  "scripts/test-mobile-claw-vpn-owner-present-pre-effect-integrity.sh"
  "scripts/test-secure-upgrade-app-attest-capture.sh"
)
NON_SHIPPING_CI_WORKFLOW_PATHS=(
  ".github/workflows/accessibility-audit.yml"
  ".github/workflows/contract-fixture-sync.yml"
  ".github/workflows/cross-repo-dep-check.yml"
  ".github/workflows/onboarding-quality.yml"
  ".github/workflows/owner-present-pre-effect-gate.yml"
  ".github/workflows/owner-present-pre-effect-integrity.yml"
  ".github/workflows/plural-rules-lint.yml"
  ".github/workflows/snapshot-record.yml"
  ".github/workflows/xcode.yml"
)

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

new_repo() {
  local repo="$1"
  git init -q -b main "${repo}"
  git -C "${repo}" config user.name "PRE-EFFECT Gate Test"
  git -C "${repo}" config user.email "pre-effect-gate@example.test"
  : > "${repo}/.keep"
  git -C "${repo}" add .keep
  git -C "${repo}" commit -qm "initial"
}

commit_all() {
  local repo="$1" message="$2"
  git -C "${repo}" add -A
  git -C "${repo}" commit -qm "${message}"
  git -C "${repo}" rev-parse HEAD
}

write_inert_ios() {
  local repo="$1" path
  for path in "${SEALED_PATHS[@]}"; do
    mkdir -p "${repo}/$(dirname "${path}")"
    cp "${ROOT}/${path}" "${repo}/${path}"
  done
  for path in "${REVIEWED_TEST_ONLY_PATHS[@]}"; do
    mkdir -p "${repo}/$(dirname "${path}")"
    cp -P "${ROOT}/${path}" "${repo}/${path}"
  done
  for path in "${SIGNAL_AUTOMATION_PATHS[@]}"; do
    mkdir -p "${repo}/$(dirname "${path}")"
    cp -p "${ROOT}/${path}" "${repo}/${path}"
  done
  for path in "${AUTOMATION_BASELINE_REL}" "${BINARY_BASELINE_REL}" \
    "${REVIEWED_BINARY_SAMPLE}" "${REVIEWED_EXTERNAL_SAMPLE}"; do
    mkdir -p "${repo}/$(dirname "${path}")"
    cp -p "${ROOT}/${path}" "${repo}/${path}"
  done
}

write_probe() {
  local output="$1" form="$2"
  mkdir -p "$(dirname "${output}")"
  case "${form}" in
    direct)
      printf '%s\n' 'struct MobileClawVPNOwnerPresentProbe {}' > "${output}"
      ;;
    composed_symbol)
      printf '%s\n' \
        'enum MobileClawVPNApprovalTransport {' \
        '    static func send() {}' \
        '}' > "${output}"
      ;;
    composed_path)
      printf '%s\n' \
        'enum MobileClawVPNRouteProbe {' \
        '    static let route = ["owner", "present", "finish"].joined(separator: "-")' \
        '}' > "${output}"
      ;;
    uppercase_symbol)
      printf '%s\n' '#define MOBILE_CLAW_VPN_APPROVAL_TRANSPORT 1' > "${output}"
      ;;
    uppercase_path)
      printf '%s\n' \
        'static const char *MOBILE_CLAW_VPN_ROUTE = "OWNER/PRESENT/FINISH";' \
        > "${output}"
      ;;
  esac
}

write_neutral_blob() {
  local output="$1"
  mkdir -p "$(dirname "${output}")"
  printf '%s\n' 'neutral opaque payload' > "${output}"
}

write_magic_blob() {
  local output="$1" kind="$2"
  mkdir -p "$(dirname "${output}")"
  case "${kind}" in
    macho) printf '\317\372\355\376\000\000\000\000' > "${output}" ;;
    fat) printf '\312\376\272\276\000\000\000\001' > "${output}" ;;
    elf) printf '\177ELF\002\001\001\000' > "${output}" ;;
    ar) printf '!<arch>\n' > "${output}" ;;
    wasm) printf '\000asm\001\000\000\000' > "${output}" ;;
    pe) printf 'MZ\220\000\003\000\000\000' > "${output}" ;;
    bitcode) printf 'BC\300\336\065\024\000\000' > "${output}" ;;
    opaque) printf '\377\376\375\374\001\002\003\004' > "${output}" ;;
  esac
}

write_passive_resource() {
  local output="$1" kind="$2"
  mkdir -p "$(dirname "${output}")"
  case "${kind}" in
    png) printf '\211PNG\015\012\032\012' > "${output}" ;;
    ttf) printf '\000\001\000\000\000\001\000\000' > "${output}" ;;
    caf) printf 'caff\000\001\000\000' > "${output}" ;;
  esac
}

write_valid_png() {
  local output="$1"
  mkdir -p "$(dirname "${output}")"
  python3 - "${output}" <<'PY'
import base64
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4f8AAAAASUVORK5CYII="
))
PY
}

write_lfs_pointer() {
  local output="$1"
  mkdir -p "$(dirname "${output}")"
  printf '%s\n' \
    'version https://git-lfs.github.com/spec/v1' \
    'oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'size 8' > "${output}"
}

write_marker() {
  local repo="$1" digest="$2"
  mkdir -p "${repo}/$(dirname "${MARKER_REL}")"
  cat > "${repo}/${MARKER_REL}" <<EOF
{
  "contract": "soyeht-mobile-claw-vpn-owner-present-runtime-activation-v1",
  "version": 1,
  "error_wire": {
    "theyos_path": "${ERROR_REL}",
    "ios_path": "${ERROR_VENDOR_REL}",
    "sha256": "${digest}"
  }
}
EOF
}

write_pin() {
  local ios="$1" pin="$2"
  mkdir -p "${ios}/$(dirname "${PIN_REL}")"
  printf '%s\n' "${pin}" > "${ios}/${PIN_REL}"
}

expect_pass() {
  local label="$1"
  shift
  if ! "$@" > "${TMP_DIR}/${label}.log" 2>&1; then
    cat "${TMP_DIR}/${label}.log"
    echo "expected pass: ${label}" >&2
    exit 1
  fi
  echo "PASS ${label}"
}

expect_fail() {
  local label="$1" expected="$2"
  shift 2
  if "$@" > "${TMP_DIR}/${label}.log" 2>&1; then
    cat "${TMP_DIR}/${label}.log"
    echo "expected failure: ${label}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected}" "${TMP_DIR}/${label}.log"; then
    cat "${TMP_DIR}/${label}.log"
    echo "missing failure reason for ${label}: ${expected}" >&2
    exit 1
  fi
  echo "PASS ${label}_refused"
}

INERT_IOS="${TMP_DIR}/inert-ios"
INERT_THEYOS="${TMP_DIR}/inert-theyos"
new_repo "${INERT_IOS}"
new_repo "${INERT_THEYOS}"
write_inert_ios "${INERT_IOS}"
commit_all "${INERT_IOS}" "sealed PRE-EFFECT boundary" >/dev/null
expect_pass inert "${CHECKER}" "${INERT_IOS}" "${INERT_THEYOS}"

UNRELATED_IOS="${TMP_DIR}/unrelated-ios"
UNRELATED_THEYOS="${TMP_DIR}/unrelated-theyos"
git clone -q "${INERT_IOS}" "${UNRELATED_IOS}"
git clone -q "${INERT_THEYOS}" "${UNRELATED_THEYOS}"
git -C "${UNRELATED_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${UNRELATED_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${UNRELATED_IOS}/TerminalApp/Soyeht/Settings"
printf '%s\n' 'struct UnrelatedSettingsProbe {}' \
  > "${UNRELATED_IOS}/TerminalApp/Soyeht/Settings/UnrelatedSettingsProbe.swift"
mkdir -p "${UNRELATED_IOS}/TerminalApp/Soyeht/Resources"
printf 'Neutral UTF-8 \342\200\224 \342\202\254\n' \
  > "${UNRELATED_IOS}/TerminalApp/Soyeht/Resources/neutral.txt"
commit_all "${UNRELATED_IOS}" "unrelated shipping change" >/dev/null
expect_pass unrelated_shipping "${CHECKER}" "${UNRELATED_IOS}" "${UNRELATED_THEYOS}"

TEST_ROOT_IOS="${TMP_DIR}/test-root-ios"
TEST_ROOT_THEYOS="${TMP_DIR}/test-root-theyos"
git clone -q "${INERT_IOS}" "${TEST_ROOT_IOS}"
git clone -q "${INERT_THEYOS}" "${TEST_ROOT_THEYOS}"
git -C "${TEST_ROOT_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${TEST_ROOT_IOS}" config user.email "pre-effect-gate@example.test"
for neutral_test_path in \
  "Tests/NeutralRootTests.swift" \
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/NeutralContractTests.swift" \
  "TerminalApp/SoyehtTests/NeutralPresentationTests.swift" \
  "TerminalApp/SoyehtMacTests/NeutralPresentationTests.swift" \
  "Native/RelayStreamGuestFFI/SwiftTests/NeutralNativeTests.swift"; do
  mkdir -p "${TEST_ROOT_IOS}/$(dirname "${neutral_test_path}")"
  printf '%s\n' 'struct NeutralTestOnlyProbe {}' \
    > "${TEST_ROOT_IOS}/${neutral_test_path}"
done
commit_all "${TEST_ROOT_IOS}" \
  "neutral files in actual test roots remain non-shipping" >/dev/null
expect_pass explicit_test_roots \
  "${CHECKER}" "${TEST_ROOT_IOS}" "${TEST_ROOT_THEYOS}"

BASELINE_MUTATION_IOS="${TMP_DIR}/baseline-mutation-ios"
BASELINE_MUTATION_THEYOS="${TMP_DIR}/baseline-mutation-theyos"
git clone -q "${INERT_IOS}" "${BASELINE_MUTATION_IOS}"
git clone -q "${INERT_THEYOS}" "${BASELINE_MUTATION_THEYOS}"
git -C "${BASELINE_MUTATION_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${BASELINE_MUTATION_IOS}" config user.email "pre-effect-gate@example.test"
printf '\n' >> "${BASELINE_MUTATION_IOS}/${REVIEWED_TEST_ONLY_PATHS[1]}"
commit_all "${BASELINE_MUTATION_IOS}" "mutate reviewed test fixture" >/dev/null
expect_fail reviewed_test_fixture_mutation \
  "Reviewed test-only PRE-EFFECT baseline changed" \
  "${CHECKER}" "${BASELINE_MUTATION_IOS}" "${BASELINE_MUTATION_THEYOS}"

CBOR_MUTATION_IOS="${TMP_DIR}/cbor-mutation-ios"
CBOR_MUTATION_THEYOS="${TMP_DIR}/cbor-mutation-theyos"
git clone -q "${INERT_IOS}" "${CBOR_MUTATION_IOS}"
git clone -q "${INERT_THEYOS}" "${CBOR_MUTATION_THEYOS}"
git -C "${CBOR_MUTATION_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${CBOR_MUTATION_IOS}" config user.email "pre-effect-gate@example.test"
printf '\000' >> "${CBOR_MUTATION_IOS}/${REVIEWED_TEST_ONLY_PATHS[2]}"
commit_all "${CBOR_MUTATION_IOS}" "mutate reviewed test CBOR" >/dev/null
expect_fail reviewed_test_cbor_mutation \
  "Reviewed test-only PRE-EFFECT baseline changed" \
  "${CHECKER}" "${CBOR_MUTATION_IOS}" "${CBOR_MUTATION_THEYOS}"

SYMLINK_BASELINE_IOS="${TMP_DIR}/symlink-baseline-ios"
SYMLINK_BASELINE_THEYOS="${TMP_DIR}/symlink-baseline-theyos"
git clone -q "${INERT_IOS}" "${SYMLINK_BASELINE_IOS}"
git clone -q "${INERT_THEYOS}" "${SYMLINK_BASELINE_THEYOS}"
git -C "${SYMLINK_BASELINE_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SYMLINK_BASELINE_IOS}" config user.email "pre-effect-gate@example.test"
rm "${SYMLINK_BASELINE_IOS}/${REVIEWED_TEST_ONLY_PATHS[11]}"
ln -s neutral-target "${SYMLINK_BASELINE_IOS}/${REVIEWED_TEST_ONLY_PATHS[11]}"
commit_all "${SYMLINK_BASELINE_IOS}" "mutate reviewed test symlink" >/dev/null
expect_fail reviewed_test_symlink_mutation \
  "Reviewed test-only PRE-EFFECT baseline changed" \
  "${CHECKER}" "${SYMLINK_BASELINE_IOS}" "${SYMLINK_BASELINE_THEYOS}"

AUTOMATION_MUTATION_IOS="${TMP_DIR}/automation-signal-mutation-ios"
AUTOMATION_MUTATION_THEYOS="${TMP_DIR}/automation-signal-mutation-theyos"
git clone -q "${INERT_IOS}" "${AUTOMATION_MUTATION_IOS}"
git clone -q "${INERT_THEYOS}" "${AUTOMATION_MUTATION_THEYOS}"
git -C "${AUTOMATION_MUTATION_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${AUTOMATION_MUTATION_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' 'POST /api/v1/mobile/claw-vpn/owner-present/finish' \
  >> "${AUTOMATION_MUTATION_IOS}/scripts/mobile-claw-vpn-dev-e2e-runner.sh"
commit_all "${AUTOMATION_MUTATION_IOS}" \
  "mutate reviewed signal-bearing automation" >/dev/null
expect_fail reviewed_automation_signal_mutation \
  "Reviewed automation signal baseline changed" \
  "${CHECKER}" "${AUTOMATION_MUTATION_IOS}" "${AUTOMATION_MUTATION_THEYOS}"

AUTOMATION_REACH_IOS="${TMP_DIR}/automation-reachability-ios"
AUTOMATION_REACH_THEYOS="${TMP_DIR}/automation-reachability-theyos"
git clone -q "${INERT_IOS}" "${AUTOMATION_REACH_IOS}"
git clone -q "${INERT_THEYOS}" "${AUTOMATION_REACH_THEYOS}"
git -C "${AUTOMATION_REACH_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${AUTOMATION_REACH_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' \
  '#!/bin/bash' \
  'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' \
  'bash "$ROOT/scripts/mobile-claw-vpn-dev-e2e-runner.sh"' \
  > "${AUTOMATION_REACH_IOS}/scripts/embed-engine.sh"
chmod +x "${AUTOMATION_REACH_IOS}/scripts/embed-engine.sh"
commit_all "${AUTOMATION_REACH_IOS}" \
  "shipping build reaches unchanged reviewed automation" >/dev/null
expect_fail unchanged_automation_reached_by_shipping_build \
  "Shipping input reaches reviewed non-shipping automation" \
  "${CHECKER}" "${AUTOMATION_REACH_IOS}" "${AUTOMATION_REACH_THEYOS}"

PBX_TEXT_IOS="${TMP_DIR}/pbx-test-text-ios"
PBX_TEXT_THEYOS="${TMP_DIR}/pbx-test-text-theyos"
git clone -q "${INERT_IOS}" "${PBX_TEXT_IOS}"
git clone -q "${INERT_THEYOS}" "${PBX_TEXT_THEYOS}"
git -C "${PBX_TEXT_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PBX_TEXT_IOS}" config user.email "pre-effect-gate@example.test"
write_probe "${PBX_TEXT_IOS}/TerminalApp/SoyehtTests/Transport.swift" direct
mkdir -p "${PBX_TEXT_IOS}/TerminalApp/Soyeht.xcodeproj"
printf '%s\n' 'PBXSourcesBuildPhase = (Transport.swift);' \
  > "${PBX_TEXT_IOS}/TerminalApp/Soyeht.xcodeproj/project.pbxproj"
commit_all "${PBX_TEXT_IOS}" "attach test-root source to app target" >/dev/null
expect_fail test_root_text_with_neutral_pbx_membership \
  "Shipping owner-present runtime signal detected" \
  "${CHECKER}" "${PBX_TEXT_IOS}" "${PBX_TEXT_THEYOS}"

PACKAGE_TEXT_IOS="${TMP_DIR}/package-test-text-ios"
PACKAGE_TEXT_THEYOS="${TMP_DIR}/package-test-text-theyos"
git clone -q "${INERT_IOS}" "${PACKAGE_TEXT_IOS}"
git clone -q "${INERT_THEYOS}" "${PACKAGE_TEXT_THEYOS}"
git -C "${PACKAGE_TEXT_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PACKAGE_TEXT_IOS}" config user.email "pre-effect-gate@example.test"
write_probe "${PACKAGE_TEXT_IOS}/Packages/Escape/Tests/Hidden/Transport.swift" direct
mkdir -p "${PACKAGE_TEXT_IOS}/Packages/Escape"
printf '%s\n' \
  '// swift-tools-version: 5.10' \
  'import PackageDescription' \
  'let package = Package(name: "Escape", products: [.library(name: "Escape", targets: ["Escape"])], targets: [.target(name: "Escape", path: "Tests/Hidden")])' \
  > "${PACKAGE_TEXT_IOS}/Packages/Escape/Package.swift"
commit_all "${PACKAGE_TEXT_IOS}" "attach test-root source to production package" >/dev/null
expect_fail test_root_text_with_neutral_package_membership \
  "Shipping owner-present runtime signal detected" \
  "${CHECKER}" "${PACKAGE_TEXT_IOS}" "${PACKAGE_TEXT_THEYOS}"

PBX_FRAMEWORK_IOS="${TMP_DIR}/pbx-test-framework-ios"
PBX_FRAMEWORK_THEYOS="${TMP_DIR}/pbx-test-framework-theyos"
git clone -q "${INERT_IOS}" "${PBX_FRAMEWORK_IOS}"
git clone -q "${INERT_THEYOS}" "${PBX_FRAMEWORK_THEYOS}"
git -C "${PBX_FRAMEWORK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PBX_FRAMEWORK_IOS}" config user.email "pre-effect-gate@example.test"
write_neutral_blob \
  "${PBX_FRAMEWORK_IOS}/TerminalApp/SoyehtTests/Fixtures/Neutral.framework/Neutral"
mkdir -p "${PBX_FRAMEWORK_IOS}/TerminalApp/Soyeht.xcodeproj"
printf '%s\n' 'PBXCopyFilesBuildPhase = (Neutral.framework);' \
  > "${PBX_FRAMEWORK_IOS}/TerminalApp/Soyeht.xcodeproj/project.pbxproj"
commit_all "${PBX_FRAMEWORK_IOS}" "embed test-root framework in app" >/dev/null
expect_fail test_root_framework_with_neutral_pbx_membership \
  "Shipping precompiled binary detected" \
  "${CHECKER}" "${PBX_FRAMEWORK_IOS}" "${PBX_FRAMEWORK_THEYOS}"

PACKAGE_BINARY_IOS="${TMP_DIR}/package-test-binary-ios"
PACKAGE_BINARY_THEYOS="${TMP_DIR}/package-test-binary-theyos"
git clone -q "${INERT_IOS}" "${PACKAGE_BINARY_IOS}"
git clone -q "${INERT_THEYOS}" "${PACKAGE_BINARY_THEYOS}"
git -C "${PACKAGE_BINARY_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PACKAGE_BINARY_IOS}" config user.email "pre-effect-gate@example.test"
write_magic_blob "${PACKAGE_BINARY_IOS}/Packages/Foo/Tests/Hidden/Transport" macho
mkdir -p "${PACKAGE_BINARY_IOS}/Packages/Foo"
printf '%s\n' \
  '// swift-tools-version: 5.10' \
  'import PackageDescription' \
  'let package = Package(name: "Foo", products: [.library(name: "Foo", targets: ["Foo"])], targets: [.target(name: "Foo", path: "Tests/Hidden")])' \
  > "${PACKAGE_BINARY_IOS}/Packages/Foo/Package.swift"
commit_all "${PACKAGE_BINARY_IOS}" "attach test-root binary to production package" >/dev/null
expect_fail test_root_binary_with_neutral_package_membership \
  "Opaque Mach-O shipping blob detected" \
  "${CHECKER}" "${PACKAGE_BINARY_IOS}" "${PACKAGE_BINARY_THEYOS}"

LFS_IOS="${TMP_DIR}/lfs-pointer-ios"
LFS_THEYOS="${TMP_DIR}/lfs-pointer-theyos"
git clone -q "${INERT_IOS}" "${LFS_IOS}"
git clone -q "${INERT_THEYOS}" "${LFS_THEYOS}"
git -C "${LFS_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${LFS_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '*.lfsbin filter=lfs diff=lfs merge=lfs -text' \
  > "${LFS_IOS}/.gitattributes"
write_lfs_pointer \
  "${LFS_IOS}/Native/RelayStreamGuestFFI/Resources/runtime.lfsbin"
commit_all "${LFS_IOS}" "external Git LFS payload pointer" >/dev/null
expect_fail external_lfs_payload_pointer \
  "External Git LFS payload pointer detected" \
  "${CHECKER}" "${LFS_IOS}" "${LFS_THEYOS}"

REMOTE_BINARY_IOS="${TMP_DIR}/remote-binary-target-ios"
REMOTE_BINARY_THEYOS="${TMP_DIR}/remote-binary-target-theyos"
git clone -q "${INERT_IOS}" "${REMOTE_BINARY_IOS}"
git clone -q "${INERT_THEYOS}" "${REMOTE_BINARY_THEYOS}"
git -C "${REMOTE_BINARY_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${REMOTE_BINARY_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${REMOTE_BINARY_IOS}/Packages/Escape"
printf '%s\n' \
  '// swift-tools-version: 5.10' \
  'import PackageDescription' \
  'let package = Package(name: "Escape", targets: [' \
  '  .binaryTarget(name: "ExternalBridge", url: "https://example.invalid/bridge.zip", checksum: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' \
  '])' \
  > "${REMOTE_BINARY_IOS}/Packages/Escape/Package.swift"
commit_all "${REMOTE_BINARY_IOS}" "add neutral remote SwiftPM binary" >/dev/null
expect_fail remote_swiftpm_binary_target \
  "Unreviewed external executable resolver detected" \
  "${CHECKER}" "${REMOTE_BINARY_IOS}" "${REMOTE_BINARY_THEYOS}"

REMOTE_SOURCE_IOS="${TMP_DIR}/remote-source-package-ios"
REMOTE_SOURCE_THEYOS="${TMP_DIR}/remote-source-package-theyos"
git clone -q "${INERT_IOS}" "${REMOTE_SOURCE_IOS}"
git clone -q "${INERT_THEYOS}" "${REMOTE_SOURCE_THEYOS}"
git -C "${REMOTE_SOURCE_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${REMOTE_SOURCE_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${REMOTE_SOURCE_IOS}/Packages/Escape"
printf '%s\n' \
  '// swift-tools-version: 5.10' \
  'import PackageDescription' \
  'let package = Package(name: "Escape", dependencies: [' \
  '  .package(url: "https://example.invalid/source.git", exact: "1.0.0")' \
  '])' \
  > "${REMOTE_SOURCE_IOS}/Packages/Escape/Package.swift"
commit_all "${REMOTE_SOURCE_IOS}" "add neutral remote SwiftPM source" >/dev/null
expect_fail remote_swiftpm_source_package \
  "Unreviewed external executable resolver detected" \
  "${CHECKER}" "${REMOTE_SOURCE_IOS}" "${REMOTE_SOURCE_THEYOS}"

REMOTE_PBX_IOS="${TMP_DIR}/remote-pbx-package-ios"
REMOTE_PBX_THEYOS="${TMP_DIR}/remote-pbx-package-theyos"
git clone -q "${INERT_IOS}" "${REMOTE_PBX_IOS}"
git clone -q "${INERT_THEYOS}" "${REMOTE_PBX_THEYOS}"
git -C "${REMOTE_PBX_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${REMOTE_PBX_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${REMOTE_PBX_IOS}/FutureExtension/Future.xcodeproj"
printf '%s\n' \
  'isa = XCRemoteSwiftPackageReference;' \
  'repositoryURL = "https://example.invalid/bridge.git";' \
  > "${REMOTE_PBX_IOS}/FutureExtension/Future.xcodeproj/project.pbxproj"
commit_all "${REMOTE_PBX_IOS}" "add neutral remote Xcode package" >/dev/null
expect_fail remote_xcode_package \
  "Unreviewed external executable resolver detected" \
  "${CHECKER}" "${REMOTE_PBX_IOS}" "${REMOTE_PBX_THEYOS}"

REVIEWED_EXTERNAL_MUTATION_IOS="${TMP_DIR}/reviewed-external-mutation-ios"
REVIEWED_EXTERNAL_MUTATION_THEYOS="${TMP_DIR}/reviewed-external-mutation-theyos"
git clone -q "${INERT_IOS}" "${REVIEWED_EXTERNAL_MUTATION_IOS}"
git clone -q "${INERT_THEYOS}" "${REVIEWED_EXTERNAL_MUTATION_THEYOS}"
git -C "${REVIEWED_EXTERNAL_MUTATION_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${REVIEWED_EXTERNAL_MUTATION_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '// descriptor mutation' \
  >> "${REVIEWED_EXTERNAL_MUTATION_IOS}/${REVIEWED_EXTERNAL_SAMPLE}"
commit_all "${REVIEWED_EXTERNAL_MUTATION_IOS}" \
  "mutate reviewed external descriptor" >/dev/null
expect_fail reviewed_external_descriptor_mutation \
  "Unreviewed external executable resolver detected" \
  "${CHECKER}" "${REVIEWED_EXTERNAL_MUTATION_IOS}" \
  "${REVIEWED_EXTERNAL_MUTATION_THEYOS}"

BINARY_MUTATION_IOS="${TMP_DIR}/reviewed-binary-mutation-ios"
BINARY_MUTATION_THEYOS="${TMP_DIR}/reviewed-binary-mutation-theyos"
git clone -q "${INERT_IOS}" "${BINARY_MUTATION_IOS}"
git clone -q "${INERT_THEYOS}" "${BINARY_MUTATION_THEYOS}"
git -C "${BINARY_MUTATION_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${BINARY_MUTATION_IOS}" config user.email "pre-effect-gate@example.test"
printf '\317\372\355\376\000\000\000\000' \
  >> "${BINARY_MUTATION_IOS}/${REVIEWED_BINARY_SAMPLE}"
commit_all "${BINARY_MUTATION_IOS}" "mutate reviewed binary resource" >/dev/null
expect_fail reviewed_binary_mutation \
  "Reviewed binary baseline changed" \
  "${CHECKER}" "${BINARY_MUTATION_IOS}" "${BINARY_MUTATION_THEYOS}"

BINARY_REACH_IOS="${TMP_DIR}/reviewed-binary-reachability-ios"
BINARY_REACH_THEYOS="${TMP_DIR}/reviewed-binary-reachability-theyos"
git clone -q "${INERT_IOS}" "${BINARY_REACH_IOS}"
git clone -q "${INERT_THEYOS}" "${BINARY_REACH_THEYOS}"
git -C "${BINARY_REACH_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${BINARY_REACH_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' \
  '#!/bin/bash' \
  'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' \
  'tail -c 8 "$ROOT/Packages/SoyehtCore/Sources/SoyehtCore/Resources/Fonts/JetBrainsMono-Regular.ttf" > "$ROOT/Bridge"' \
  > "${BINARY_REACH_IOS}/scripts/embed-engine.sh"
chmod +x "${BINARY_REACH_IOS}/scripts/embed-engine.sh"
commit_all "${BINARY_REACH_IOS}" \
  "shipping build reaches unchanged reviewed binary" >/dev/null
expect_fail unchanged_binary_reached_by_shipping_build \
  "Shipping build input reaches reviewed binary payload" \
  "${CHECKER}" "${BINARY_REACH_IOS}" "${BINARY_REACH_THEYOS}"

TRAILING_PAYLOAD_IOS="${TMP_DIR}/passive-resource-trailing-payload-ios"
TRAILING_PAYLOAD_THEYOS="${TMP_DIR}/passive-resource-trailing-payload-theyos"
git clone -q "${INERT_IOS}" "${TRAILING_PAYLOAD_IOS}"
git clone -q "${INERT_THEYOS}" "${TRAILING_PAYLOAD_THEYOS}"
git -C "${TRAILING_PAYLOAD_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${TRAILING_PAYLOAD_IOS}" config user.email "pre-effect-gate@example.test"
TRAILING_RESOURCE="TerminalApp/Soyeht/Assets.xcassets/Neutral.imageset/neutral.png"
write_valid_png "${TRAILING_PAYLOAD_IOS}/${TRAILING_RESOURCE}"
printf '\317\372\355\376\000\000\000\000' \
  >> "${TRAILING_PAYLOAD_IOS}/${TRAILING_RESOURCE}"
printf '%s\n' \
  '#!/bin/bash' \
  'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' \
  'tail -c 8 "$ROOT/TerminalApp/Soyeht/Assets.xcassets/Neutral.imageset/neutral.png" > "$ROOT/Bridge"' \
  > "${TRAILING_PAYLOAD_IOS}/scripts/embed-engine.sh"
chmod +x "${TRAILING_PAYLOAD_IOS}/scripts/embed-engine.sh"
commit_all "${TRAILING_PAYLOAD_IOS}" \
  "valid passive resource with trailing executable payload" >/dev/null
expect_fail passive_resource_with_trailing_executable_payload \
  "Opaque unclassified shipping blob detected" \
  "${CHECKER}" "${TRAILING_PAYLOAD_IOS}" "${TRAILING_PAYLOAD_THEYOS}"

SEALED_IOS="${TMP_DIR}/sealed-mutation-ios"
SEALED_THEYOS="${TMP_DIR}/sealed-mutation-theyos"
git clone -q "${INERT_IOS}" "${SEALED_IOS}"
git clone -q "${INERT_THEYOS}" "${SEALED_THEYOS}"
git -C "${SEALED_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SEALED_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '// runtime crossing' >> "${SEALED_IOS}/${SEALED_PATHS[0]}"
commit_all "${SEALED_IOS}" "mutate sealed boundary" >/dev/null
expect_fail sealed_boundary "requires the ODB-verified activation marker" \
  "${CHECKER}" "${SEALED_IOS}" "${SEALED_THEYOS}"

# Every runtime form is injected at the real path of every shipping surface.
for surface_pair in "${SURFACES[@]}"; do
  surface="${surface_pair%%:*}"
  relative_path="${surface_pair#*:}"
  for form in direct composed_symbol composed_path; do
    CASE_IOS="${TMP_DIR}/${surface}-${form}-ios"
    CASE_THEYOS="${TMP_DIR}/${surface}-${form}-theyos"
    git clone -q "${INERT_IOS}" "${CASE_IOS}"
    git clone -q "${INERT_THEYOS}" "${CASE_THEYOS}"
    git -C "${CASE_IOS}" config user.name "PRE-EFFECT Gate Test"
    git -C "${CASE_IOS}" config user.email "pre-effect-gate@example.test"
    write_probe "${CASE_IOS}/${relative_path}" "${form}"
    if [[ "${relative_path}" == *.sh \
      || "${relative_path}" == *.py \
      || "${relative_path}" == *.rb ]]; then
      chmod +x "${CASE_IOS}/${relative_path}"
    fi
    commit_all "${CASE_IOS}" "${form} crossing in ${surface}" >/dev/null
    expect_fail "${surface}_${form}" "requires the ODB-verified activation marker" \
      "${CHECKER}" "${CASE_IOS}" "${CASE_THEYOS}"
  done
done

for uppercase_pair in "${UPPERCASE_CASES[@]}"; do
  uppercase_form="${uppercase_pair%%:*}"
  uppercase_path="${uppercase_pair#*:}"
  UPPERCASE_IOS="${TMP_DIR}/${uppercase_form}-ios"
  UPPERCASE_THEYOS="${TMP_DIR}/${uppercase_form}-theyos"
  git clone -q "${INERT_IOS}" "${UPPERCASE_IOS}"
  git clone -q "${INERT_THEYOS}" "${UPPERCASE_THEYOS}"
  git -C "${UPPERCASE_IOS}" config user.name "PRE-EFFECT Gate Test"
  git -C "${UPPERCASE_IOS}" config user.email "pre-effect-gate@example.test"
  write_probe "${UPPERCASE_IOS}/${uppercase_path}" "${uppercase_form}"
  commit_all "${UPPERCASE_IOS}" \
    "${uppercase_form} uppercase Native crossing" >/dev/null
  expect_fail "${uppercase_form}" "requires the ODB-verified activation marker" \
    "${CHECKER}" "${UPPERCASE_IOS}" "${UPPERCASE_THEYOS}"
done

for binary_pair in "${BINARY_SURFACES[@]}"; do
  binary_label="${binary_pair%%:*}"
  binary_path="${binary_pair#*:}"
  BINARY_IOS="${TMP_DIR}/${binary_label}-ios"
  BINARY_THEYOS="${TMP_DIR}/${binary_label}-theyos"
  git clone -q "${INERT_IOS}" "${BINARY_IOS}"
  git clone -q "${INERT_THEYOS}" "${BINARY_THEYOS}"
  git -C "${BINARY_IOS}" config user.name "PRE-EFFECT Gate Test"
  git -C "${BINARY_IOS}" config user.email "pre-effect-gate@example.test"
  write_neutral_blob "${BINARY_IOS}/${binary_path}"
  case "${binary_path}" in
    *.a|*.o) ;;
    *) chmod +x "${BINARY_IOS}/${binary_path}" ;;
  esac
  commit_all "${BINARY_IOS}" "neutral precompiled binary in ${binary_label}" >/dev/null
  expect_fail "${binary_label}" "requires the ODB-verified activation marker" \
    "${CHECKER}" "${BINARY_IOS}" "${BINARY_THEYOS}"
done

for magic_pair in "${MAGIC_SURFACES[@]}"; do
  magic_label="${magic_pair%%:*}"
  magic_remainder="${magic_pair#*:}"
  magic_path="${magic_remainder%%:*}"
  magic_remainder="${magic_remainder#*:}"
  magic_kind="${magic_remainder%%:*}"
  magic_mode="${magic_remainder#*:}"
  MAGIC_IOS="${TMP_DIR}/${magic_label}-ios"
  MAGIC_THEYOS="${TMP_DIR}/${magic_label}-theyos"
  git clone -q "${INERT_IOS}" "${MAGIC_IOS}"
  git clone -q "${INERT_THEYOS}" "${MAGIC_THEYOS}"
  git -C "${MAGIC_IOS}" config user.name "PRE-EFFECT Gate Test"
  git -C "${MAGIC_IOS}" config user.email "pre-effect-gate@example.test"
  write_magic_blob "${MAGIC_IOS}/${magic_path}" "${magic_kind}"
  if [[ "${magic_mode}" == "100755" ]]; then
    chmod +x "${MAGIC_IOS}/${magic_path}"
  fi
  commit_all "${MAGIC_IOS}" "neutral ${magic_kind} blob without extension" >/dev/null
  expect_fail "${magic_label}" "requires the ODB-verified activation marker" \
    "${CHECKER}" "${MAGIC_IOS}" "${MAGIC_THEYOS}"
done

BINARY_LINK_IOS="${TMP_DIR}/binary-bundle-symlink-ios"
BINARY_LINK_THEYOS="${TMP_DIR}/binary-bundle-symlink-theyos"
git clone -q "${INERT_IOS}" "${BINARY_LINK_IOS}"
git clone -q "${INERT_THEYOS}" "${BINARY_LINK_THEYOS}"
git -C "${BINARY_LINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${BINARY_LINK_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${BINARY_LINK_IOS}/FutureExtension/Binaries"
ln -s neutral-target \
  "${BINARY_LINK_IOS}/FutureExtension/Binaries/Future.xcframework"
commit_all "${BINARY_LINK_IOS}" "precompiled binary bundle symlink" >/dev/null
expect_fail binary_bundle_symlink "Opaque non-regular shipping entry detected" \
  "${CHECKER}" "${BINARY_LINK_IOS}" "${BINARY_LINK_THEYOS}"

OPAQUE_LINK_IOS="${TMP_DIR}/opaque-symlink-ios"
OPAQUE_LINK_THEYOS="${TMP_DIR}/opaque-symlink-theyos"
git clone -q "${INERT_IOS}" "${OPAQUE_LINK_IOS}"
git clone -q "${INERT_THEYOS}" "${OPAQUE_LINK_THEYOS}"
git -C "${OPAQUE_LINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${OPAQUE_LINK_IOS}" config user.email "pre-effect-gate@example.test"
mkdir -p "${OPAQUE_LINK_IOS}/Native"
ln -s neutral-target "${OPAQUE_LINK_IOS}/Native/TransportLink"
commit_all "${OPAQUE_LINK_IOS}" "opaque shipping symlink" >/dev/null
expect_fail opaque_symlink "Opaque non-regular shipping entry detected" \
  "${CHECKER}" "${OPAQUE_LINK_IOS}" "${OPAQUE_LINK_THEYOS}"

GITLINK_IOS="${TMP_DIR}/opaque-gitlink-ios"
GITLINK_THEYOS="${TMP_DIR}/opaque-gitlink-theyos"
git clone -q "${INERT_IOS}" "${GITLINK_IOS}"
git clone -q "${INERT_THEYOS}" "${GITLINK_THEYOS}"
git -C "${GITLINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${GITLINK_IOS}" config user.email "pre-effect-gate@example.test"
GITLINK_TARGET="$(git -C "${GITLINK_IOS}" rev-parse HEAD)"
git -C "${GITLINK_IOS}" update-index --add \
  --cacheinfo "160000,${GITLINK_TARGET},Native/TransportBridge"
git -C "${GITLINK_IOS}" commit -qm "opaque shipping gitlink"
expect_fail opaque_gitlink "requires the ODB-verified activation marker" \
  "${CHECKER}" "${GITLINK_IOS}" "${GITLINK_THEYOS}"

MARKER_IOS="${TMP_DIR}/marker-ios"
MARKER_THEYOS="${TMP_DIR}/marker-theyos"
git clone -q "${INERT_IOS}" "${MARKER_IOS}"
git clone -q "${INERT_THEYOS}" "${MARKER_THEYOS}"
git -C "${MARKER_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_IOS}" config user.email "pre-effect-gate@example.test"
git -C "${MARKER_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_THEYOS}" config user.email "pre-effect-gate@example.test"
write_probe "${MARKER_IOS}/${SURFACES[0]#*:}" direct
commit_all "${MARKER_IOS}" "runtime with marker" >/dev/null
write_marker "${MARKER_THEYOS}" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
commit_all "${MARKER_THEYOS}" "marker without error wire" >/dev/null
expect_fail marker_without_error "requires the authoritative error-wire fixture" \
  "${CHECKER}" "${MARKER_IOS}" "${MARKER_THEYOS}"

CLOSED_IOS="${TMP_DIR}/closed-ios"
CLOSED_THEYOS="${TMP_DIR}/closed-theyos"
new_repo "${CLOSED_IOS}"
new_repo "${CLOSED_THEYOS}"
write_inert_ios "${CLOSED_IOS}"
write_probe "${CLOSED_IOS}/${SURFACES[0]#*:}" direct
mkdir -p "${CLOSED_THEYOS}/$(dirname "${ERROR_REL}")"
printf '%s\n' '{"contract":"opaque-error-v1"}' > "${CLOSED_THEYOS}/${ERROR_REL}"
ERROR_SHA="$(sha256_file "${CLOSED_THEYOS}/${ERROR_REL}")"
write_marker "${CLOSED_THEYOS}" "${ERROR_SHA}"
CLOSED_THEYOS_HEAD="$(commit_all "${CLOSED_THEYOS}" "closed error contract")"
mkdir -p "${CLOSED_IOS}/$(dirname "${ERROR_VENDOR_REL}")"
cp "${CLOSED_THEYOS}/${ERROR_REL}" "${CLOSED_IOS}/${ERROR_VENDOR_REL}"
write_pin "${CLOSED_IOS}" "${CLOSED_THEYOS_HEAD}"
commit_all "${CLOSED_IOS}" "closed iOS crossing" >/dev/null
git clone -q --bare "${CLOSED_THEYOS}" "${TMP_DIR}/closed-origin.git"
git -C "${CLOSED_THEYOS}" remote add origin "${TMP_DIR}/closed-origin.git"
expect_pass closed "${CHECKER}" "${CLOSED_IOS}" "${CLOSED_THEYOS}"

VENDOR_IOS="${TMP_DIR}/vendor-drift-ios"
VENDOR_THEYOS="${TMP_DIR}/vendor-drift-theyos"
git clone -q "${CLOSED_IOS}" "${VENDOR_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${VENDOR_THEYOS}"
git -C "${VENDOR_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${VENDOR_IOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '{"contract":"drift"}' > "${VENDOR_IOS}/${ERROR_VENDOR_REL}"
commit_all "${VENDOR_IOS}" "error vendor drift" >/dev/null
expect_fail vendor_drift "must be byte-identical" \
  "${CHECKER}" "${VENDOR_IOS}" "${VENDOR_THEYOS}"

SYMLINK_IOS="${TMP_DIR}/vendor-symlink-ios"
SYMLINK_THEYOS="${TMP_DIR}/vendor-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${SYMLINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${SYMLINK_THEYOS}"
git -C "${SYMLINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SYMLINK_IOS}" config user.email "pre-effect-gate@example.test"
mv "${SYMLINK_IOS}/${ERROR_VENDOR_REL}" "${SYMLINK_IOS}/error-target.json"
ln -s "../../../error-target.json" "${SYMLINK_IOS}/${ERROR_VENDOR_REL}"
commit_all "${SYMLINK_IOS}" "error vendor symlink" >/dev/null
expect_fail vendor_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${SYMLINK_IOS}" "${SYMLINK_THEYOS}"

MISSING_IOS="${TMP_DIR}/missing-vendor-ios"
MISSING_THEYOS="${TMP_DIR}/missing-vendor-theyos"
git clone -q "${CLOSED_IOS}" "${MISSING_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MISSING_THEYOS}"
git -C "${MISSING_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MISSING_IOS}" config user.email "pre-effect-gate@example.test"
rm "${MISSING_IOS}/${ERROR_VENDOR_REL}"
commit_all "${MISSING_IOS}" "missing error vendor" >/dev/null
expect_fail missing_vendor "requires the iOS error-wire vendor" \
  "${CHECKER}" "${MISSING_IOS}" "${MISSING_THEYOS}"

SOURCE_LINK_IOS="${TMP_DIR}/source-symlink-ios"
SOURCE_LINK_THEYOS="${TMP_DIR}/source-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${SOURCE_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${SOURCE_LINK_THEYOS}"
git -C "${SOURCE_LINK_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${SOURCE_LINK_THEYOS}" config user.email "pre-effect-gate@example.test"
mv "${SOURCE_LINK_THEYOS}/${ERROR_REL}" "${SOURCE_LINK_THEYOS}/error-source-target.json"
ln -s "../../../../error-source-target.json" "${SOURCE_LINK_THEYOS}/${ERROR_REL}"
commit_all "${SOURCE_LINK_THEYOS}" "error source symlink" >/dev/null
expect_fail source_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${SOURCE_LINK_IOS}" "${SOURCE_LINK_THEYOS}"

MARKER_LINK_IOS="${TMP_DIR}/marker-symlink-ios"
MARKER_LINK_THEYOS="${TMP_DIR}/marker-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${MARKER_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MARKER_LINK_THEYOS}"
git -C "${MARKER_LINK_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MARKER_LINK_THEYOS}" config user.email "pre-effect-gate@example.test"
mv "${MARKER_LINK_THEYOS}/${MARKER_REL}" "${MARKER_LINK_THEYOS}/marker-target.json"
ln -s "../../../../marker-target.json" "${MARKER_LINK_THEYOS}/${MARKER_REL}"
commit_all "${MARKER_LINK_THEYOS}" "activation marker symlink" >/dev/null
expect_fail marker_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${MARKER_LINK_IOS}" "${MARKER_LINK_THEYOS}"

PIN_LINK_IOS="${TMP_DIR}/pin-symlink-ios"
PIN_LINK_THEYOS="${TMP_DIR}/pin-symlink-theyos"
git clone -q "${CLOSED_IOS}" "${PIN_LINK_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${PIN_LINK_THEYOS}"
git -C "${PIN_LINK_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PIN_LINK_IOS}" config user.email "pre-effect-gate@example.test"
mv "${PIN_LINK_IOS}/${PIN_REL}" "${PIN_LINK_IOS}/pin-target.sha"
ln -s "../pin-target.sha" "${PIN_LINK_IOS}/${PIN_REL}"
commit_all "${PIN_LINK_IOS}" "cross-repo pin symlink" >/dev/null
expect_fail pin_symlink "must be a regular 100644 Git blob" \
  "${CHECKER}" "${PIN_LINK_IOS}" "${PIN_LINK_THEYOS}"

PIN_IOS="${TMP_DIR}/unlanded-pin-ios"
PIN_THEYOS="${TMP_DIR}/unlanded-pin-theyos"
git clone -q "${CLOSED_IOS}" "${PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${PIN_THEYOS}"
git -C "${PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PIN_IOS}" config user.email "pre-effect-gate@example.test"
git -C "${PIN_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${PIN_THEYOS}" config user.email "pre-effect-gate@example.test"
SIDE_TREE="$(git -C "${PIN_THEYOS}" rev-parse HEAD^{tree})"
SIDE_PIN="$(printf '%s\n' 'unlanded error pin' | git -C "${PIN_THEYOS}" commit-tree "${SIDE_TREE}")"
write_pin "${PIN_IOS}" "${SIDE_PIN}"
commit_all "${PIN_IOS}" "unlanded error pin" >/dev/null
expect_fail unlanded_pin "is not landed" "${CHECKER}" "${PIN_IOS}" "${PIN_THEYOS}"

MISSING_PIN_IOS="${TMP_DIR}/pin-before-error-ios"
MISSING_PIN_THEYOS="${TMP_DIR}/pin-before-error-theyos"
git clone -q "${CLOSED_IOS}" "${MISSING_PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${MISSING_PIN_THEYOS}"
git -C "${MISSING_PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${MISSING_PIN_IOS}" config user.email "pre-effect-gate@example.test"
PRE_ERROR_PIN="$(git -C "${MISSING_PIN_THEYOS}" rev-list --max-parents=0 HEAD)"
write_pin "${MISSING_PIN_IOS}" "${PRE_ERROR_PIN}"
commit_all "${MISSING_PIN_IOS}" "pin predates error wire" >/dev/null
expect_fail pin_without_error "does not contain the owner-present error wire" \
  "${CHECKER}" "${MISSING_PIN_IOS}" "${MISSING_PIN_THEYOS}"

STALE_PIN_IOS="${TMP_DIR}/stale-pin-ios"
STALE_PIN_THEYOS="${TMP_DIR}/stale-pin-theyos"
git clone -q "${CLOSED_IOS}" "${STALE_PIN_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${STALE_PIN_THEYOS}"
git -C "${STALE_PIN_IOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${STALE_PIN_IOS}" config user.email "pre-effect-gate@example.test"
git -C "${STALE_PIN_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${STALE_PIN_THEYOS}" config user.email "pre-effect-gate@example.test"
printf '%s\n' '{"contract":"opaque-error-v1","revision":2}' \
  > "${STALE_PIN_THEYOS}/${ERROR_REL}"
STALE_SHA="$(sha256_file "${STALE_PIN_THEYOS}/${ERROR_REL}")"
write_marker "${STALE_PIN_THEYOS}" "${STALE_SHA}"
commit_all "${STALE_PIN_THEYOS}" "source advanced past pin" >/dev/null
cp "${STALE_PIN_THEYOS}/${ERROR_REL}" "${STALE_PIN_IOS}/${ERROR_VENDOR_REL}"
commit_all "${STALE_PIN_IOS}" "vendor follows unpinned source" >/dev/null
expect_fail stale_pin "must be byte-identical" \
  "${CHECKER}" "${STALE_PIN_IOS}" "${STALE_PIN_THEYOS}"

DIGEST_IOS="${TMP_DIR}/wrong-digest-ios"
DIGEST_THEYOS="${TMP_DIR}/wrong-digest-theyos"
git clone -q "${CLOSED_IOS}" "${DIGEST_IOS}"
git clone -q "${TMP_DIR}/closed-origin.git" "${DIGEST_THEYOS}"
git -C "${DIGEST_THEYOS}" config user.name "PRE-EFFECT Gate Test"
git -C "${DIGEST_THEYOS}" config user.email "pre-effect-gate@example.test"
write_marker "${DIGEST_THEYOS}" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
commit_all "${DIGEST_THEYOS}" "wrong marker digest" >/dev/null
expect_fail marker_digest "does not match authoritative error-wire bytes" \
  "${CHECKER}" "${DIGEST_IOS}" "${DIGEST_THEYOS}"

echo "iOS owner-present PRE-EFFECT mutation matrix passed."
