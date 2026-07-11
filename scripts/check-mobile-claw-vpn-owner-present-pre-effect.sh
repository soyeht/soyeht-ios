#!/bin/bash
# Durable iOS crossing guard from the sealed PRE-EFFECT boundary to shipping runtime.
set -euo pipefail

IOS_DIR="${1:?usage: $0 SOYEHT_IOS_DIR THEYOS_DIR}"
THEYOS_DIR="${2:?usage: $0 SOYEHT_IOS_DIR THEYOS_DIR}"

MARKER_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_runtime_activation_v1.json"
ERROR_SOURCE_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
ERROR_VENDOR_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
PIN_REL="scripts/cross-repo-contract.sha"
AUTOMATION_SIGNAL_BASELINE_REL="scripts/mobile-claw-vpn-owner-present-automation-baseline.tsv"
BINARY_BASELINE_REL="scripts/mobile-claw-vpn-owner-present-binary-baseline.tsv"

# These are the reviewed, inert type/contract surfaces. Changing one is itself
# a crossing until the shared runtime marker and error contract are complete.
SEALED_PRE_EFFECT_BLOBS=(
  "Packages/SoyehtCore/Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift:09892d9826cebe47755a24591bd2994c1166292f"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/MobileClawVPNDevE2EExecutionTupleV1.swift:b67e58e14544f1e2e29e57376f3239cbbdafb1d5"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalContextV2DTO.swift:c464ea12594657e3bbcf46121febc56e23b9897e"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalV2DTO.swift:c26db58cdc5c9e8dddfb98f21eda4c024ba5ac79"
)

# Test-root names do not prove target membership. These are the only reviewed
# test-only entries that need an exception from the uniform signal/opaque
# classifier. Their full Git identity is frozen with this base-owned checker.
REVIEWED_TEST_ONLY_ENTRIES=(
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_approval_v2_execution_vectors.json|100644|blob|2d3cb810dae5ec875d7a8c2ea190fedf0cb5828b"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_success_wire_v1.json|100644|blob|537542c2ac1b736cc6704aa55b53d75d6f6a9232"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/OwnerCert/owner_cert_auth.cbor|100644|blob|06e08609741792aa7ea872b50648c7dab3326f26"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNAPIClientTests.swift|100644|blob|8b8c0200ebae682dbf21a9a2bb0f6b386409c0a0"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryGuardTests.swift|100644|blob|497ecbf3188c1f7b035edcbe344e9f5477d0d06e"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryTestSupport.swift|100644|blob|51bf8ac9704e5c2827bc12574eb22987e76dbf6d"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentBoundaryTests.swift|100644|blob|b3952b989afadfd76b824f1abdf078e769e31a73"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentCancellationTests.swift|100644|blob|095a3d4441cdd445e1128c144d5cfdf71c3d49b5"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/MobileClawVPNOwnerPresentSuccessWireTests.swift|100644|blob|08318becfb6bc0cdff488441ae99a103124ff029"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerApprovalV2ClientTests.swift|100644|blob|3795ef774c3e9ac96af79545f301f782b210d6e3"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerApprovalV2CrossLanguageVectorTests.swift|100644|blob|1d82fdabce8331e61781e4e4fa8e8c388ca9b99a"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/AppCommandRegistry.swift|120000|blob|74891072e3f21ac738f91d2a6a7d8044da459600"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/AppSupportDirectory.swift|120000|blob|718c4f778a29244ab8d5cd966801c746a4126129"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ClawDrawerViewModel.swift|120000|blob|22af1c8c6bae19e38bf99afbfd45edfee5429cf2"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ConversationStore.swift|120000|blob|890907cdf92fb5d2cd09487a9702b38a9c6c40f7"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/DaemonPairMachineStageClient.swift|120000|blob|92485cce8e4dd063c25e8944c992d7b75c82dbba"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/InstalledClawsProvider.swift|120000|blob|d308f91e86290c06b6321bf245d78d09ff271854"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/JoinExistingCapability.swift|120000|blob|3b3eda1d40cf7a46af86fe18db5c96964b3b996a"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacClawInstallDecision.swift|120000|blob|a68747aace4a2515a103551eb47d51c69cdd4dd1"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacGuestImageReadinessGate.swift|120000|blob|28e77dff671fde3b562789e08f2eea5ed7412ca1"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacGuestImageRecovery.swift|120000|blob|8427b34cfb8662827ea211878803d814d21a5530"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MacQRCodeImageFactory.swift|120000|blob|dcc1f3658dc72c7c3a97792a71d1e4c8edeb4078"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/MainMenu|120000|blob|2602343e3e74ecc15cd55eb59fc720bc6921240f"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/Model|120000|blob|11b4dd104c4afee8006f4aeee8156ac6351fb8b1"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/ObservationTracker.swift|120000|blob|eb46b585ad938445607a740b596b1a545c888a60"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/PairingStore.swift|120000|blob|fad02454fc69a1367259bed01a9832844294030e"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/PaneAttachRegistry.swift|120000|blob|28f110234cbb1fab0443a443c21adc46bb174c8f"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSEnvironment.swift|120000|blob|bc553316cc7481f5fe7e209899b919794c17fb95"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSHealthProber.swift|120000|blob|0bb3139420d4ac3de23a75fbbb95ce6d38865b07"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSInstaller.swift|120000|blob|fc73df3b36f449b10da630a0ac241fba0fbb1996"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/TheyOSUninstallPlan.swift|120000|blob|b9199cc1478045566e2f539f32ae8e24d6f7bfe4"
  "TerminalApp/SoyehtMacTests/Sources/SoyehtMacDomain/WorkspaceStore.swift|120000|blob|5185536a5b361ccccd40d90e083897540850c129"
)

# This exact ordered set must match the base-owned TSV. The TSV breaks the
# self-hash cycle for the checker/harness/workflow while preserving full ODB
# identity for every existing signal-bearing automation exemption.
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
REVIEWED_AUTOMATION_SIGNAL_ENTRIES=()

# These current test, documentation, and automation blobs reference reviewed
# tooling/resources without reaching a shipping build. Identity, not pathname,
# is the exemption; any mutation is scanned again.
REVIEWED_REFERENCE_ONLY_ENTRIES=(
  "docs/claw-store-architecture.md|100644|blob|815056e14a6b55f0a2a943e0c83695713f73f442"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/ClawStoreContractConstantsGuardTests.swift|100644|blob|ceeb0ab8338256245497ea08b3d7ee08ad722998"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/Generated/ClawStoreContractConstants.generated.swift|100644|blob|35e91a274bdf0bdb3d98c9e7aef40f5e4f974a7c"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/Avatar/README.md|100644|blob|204f585603cef8a95fadb03bd0414be19dcafced"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/BootstrapErrorCode/bootstrap_error_codes.json|100644|blob|80626ae46d6c459471f1c17227d3f67b3652f4f8"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/GuestImageFailureCode/guest_image_failure_codes.json|100644|blob|a34ae5d3c1f54a65c8dded57e7b5696bdfa3f908"
  "Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/OwnerCert/README.md|100644|blob|de04c14b8c786623409b3b4a652c1109255805ff"
  "QA/scripts/run_claw_store_matrix.py|100755|blob|d0410097cef9b1efb65542f2148ca5ece824ef84"
  "QA/scripts/run_claw_client_ui_smoke.py|100644|blob|558ce4c5f143eae96616cddccefc4ad0e96200c7"
  "QA/scripts/run_file_live_appium.py|100644|blob|b49d448c45509098141705ce870709749094b8c1"
  "QA/scripts/test_terminal_scroll.py|100644|blob|ae2e8c978c94cd8c69d824018f2658f1227d7967"
  "TerminalApp/SoyehtMacTests/Tests/DevEmbeddedEngineSmokeTests.swift|100644|blob|a1a21ff229684d1f8de365f2e8396d8f5683ffe3"
  "docs/macos-local-attestation-capture-runbook.md|100644|blob|548a7eee27dde8eca4c98a8adf3f395ef3853403"
  "docs/secure-upgrade-app-attest-capture-runbook.md|100644|blob|cf06c31e00cfe5582d7eac91179a34022b4d19cc"
  "scripts/gen-claw-store-contract-constants.py|100644|blob|bca4ca2e68d6bef5052f3835b81e5c225bad958a"
  "scripts/mobile-claw-vpn-dev-e2e-owner-request.sh|100755|blob|9d40c7e2f02ce667f9ded6798d456ddd69c609dc"
  "scripts/mobile-claw-vpn-dev-e2e-preflight.sh|100755|blob|0c08c8670c74922250462d1b75b1a48aed8d934a"
  "scripts/test-mobile-claw-vpn-dev-e2e-preflight.sh|100755|blob|830a9c6082ea37857bc54237553b30432e3e8312"
  "scripts/test-secure-upgrade-app-attest-capture.sh|100755|blob|525470c1a73f106b4dc0390b2fdc4039abced35b"
)

# Existing dependency resolvers and artifact provenance inputs are allowed only
# at their reviewed identities. A removed resolver is safe; a new or changed
# resolver is a crossing because its executable bytes do not live in this ODB.
REVIEWED_EXTERNAL_CODE_ENTRIES=(
  ".github/workflows/accessibility-audit.yml|100644|blob|34d8132d424d427ee1a7fd7f3ba8fc4e1b815c27"
  ".github/workflows/cross-repo-dep-check.yml|100644|blob|66fc5e4a99121d01c3cef7d8c23d5d9ddb18d109"
  ".github/workflows/macos-release.yml|100644|blob|509389030f866c9a4cf860e5ed49b3f8fe47f83f"
  ".github/workflows/onboarding-quality.yml|100644|blob|f93258585fd2a533049712a10013aa833995c2b9"
  ".github/workflows/plural-rules-lint.yml|100644|blob|82077934b9651b895881b5ed8cf2761725ef057f"
  ".github/workflows/snapshot-record.yml|100644|blob|50a0a106fb7de2f5bd357d6d794145e230301a0b"
  ".github/workflows/xcode.yml|100644|blob|4b8ca2282ab70e33ba79408c997108ff5e6ecff2"
  "Makefile|100644|blob|c512ed200c88e0a4e6551c1c76d1d152d48ee6d6"
  "Native/RelayStreamGuestFFI/Cargo.lock|100644|blob|36098cc8bd63548682a067bc4764a4d26630e93b"
  "Native/RelayStreamGuestFFI/Cargo.toml|100644|blob|c355209f2ec690f6d2e36caef13c69823d2fd5f5"
  "Native/RelayStreamGuestFFI/Package.swift|100644|blob|1b1128718d3a82c652ea29e5130ddd2c857664b7"
  "Package.resolved|100644|blob|8774fb182ee90c27d9f627b0984f7e0a8056b3af"
  "Package.swift|100644|blob|0265194fcfa53ced8a7675112c6e91b5d20be4f3"
  "Packages/SoyehtCore/Package.resolved|100644|blob|ba5e6c7eceaa1f6104a24586cbc018deeecf8693"
  "Packages/SoyehtCore/Package.swift|100644|blob|269c6af249d525b1639b20fad988a1a2acf519cd"
  "QA/contract-smoke.sh|100755|blob|b382d7dff95cc3d4e2363de33b31dfc1507f2308"
  "TerminalApp/Soyeht.xcodeproj/project.pbxproj|100644|blob|4d749a653d83348b30ce80e23778073fd356f8a9"
  "TerminalApp/Soyeht.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved|100644|blob|80df6f07da9f77e9ccfcb31f201f1b803b83ce7a"
  "TerminalApp/SoyehtMac.xcodeproj/project.pbxproj|100644|blob|911bdd07f70e1a0ffc11c2737e39bd1391a0847b"
  "TerminalApp/SoyehtMacTests/Package.resolved|100644|blob|ba5e6c7eceaa1f6104a24586cbc018deeecf8693"
  "TerminalApp/SoyehtMacTests/Package.swift|100644|blob|15353b048c87a906cf2eabf2843ffc481e1f45c3"
  "scripts/fetch-engine.sh|100755|blob|f43dbceaa70fc986807f551e4bc6f59937c0521f"
  "scripts/theyos-engine.sha256|100644|blob|72869aeb5894a0f4bbf112fed3abe664d70589a7"
  "scripts/theyos-engine.version|100644|blob|3bfcb4996f32116a7dae73f01a2f951129569c3a"
)
REVIEWED_BINARY_ENTRIES=()

# Exact dev/test/CI artifacts that are not consumed by a shipping build. Every
# other path is classified from its ODB type and content.
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
  "scripts/mobile-claw-vpn-owner-present-automation-baseline.tsv"
  "scripts/mobile-claw-vpn-owner-present-binary-baseline.tsv"
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

DIRECT_PATTERN='owner[-_ -]?present|owner_approval_consumed|RevalidatedCapability|ConsumedCapability|PointOfUsePermit|proof[-_ ]?token|mesh_c_owner_present_offer_control|owner_present_mint_offer'
DOMAIN_PATTERN='MobileClawVPN|mobileClawVPN|mobile_claw_vpn|mobile-claw-vpn'
SECURITY_PATTERN='OwnerApproval|ownerApproval|owner_approval|Passkey|passkey|WebAuthn|webauthn|Proof|proof|MintLease|RevalidatedCapability|ConsumedCapability|PointOfUsePermit|ApprovalTransport|approvalTransport|approval_transport|Ceremony|ceremony|PasskeyAssertion|OwnerAssertion'

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
AUTOMATION_REFERENCE_PATTERNS="${TMP_DIR}/automation-reference-patterns"
BINARY_REFERENCE_PATTERNS="${TMP_DIR}/binary-reference-patterns"
: > "${AUTOMATION_REFERENCE_PATTERNS}"
: > "${BINARY_REFERENCE_PATTERNS}"
for reference_path in "${NON_SHIPPING_AUTOMATION_PATHS[@]}" \
  "${NON_SHIPPING_CI_WORKFLOW_PATHS[@]}"; do
  printf '%s\n%s\n' "${reference_path}" "${reference_path##*/}" \
    >> "${AUTOMATION_REFERENCE_PATTERNS}"
done
LC_ALL=C sort -u -o "${AUTOMATION_REFERENCE_PATTERNS}" \
  "${AUTOMATION_REFERENCE_PATTERNS}"

IOS_HEAD_SHA="$(git -C "${IOS_DIR}" rev-parse HEAD)"
THEYOS_HEAD_SHA="$(git -C "${THEYOS_DIR}" rev-parse HEAD)"

materialize_regular_blob() {
  local repo="$1" commit="$2" path="$3" destination="$4" label="$5"
  local allowed_modes="${6:-100644}"
  local entry mode type object mode_description
  entry="$(git -C "${repo}" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' \
    "${commit}" -- ":(literal)${path}")"
  if [[ -z "${entry}" ]]; then
    return 1
  fi
  read -r mode type object <<< "${entry}"
  mode_description="${allowed_modes// / or }"
  if [[ "${type}" != "blob" ]]; then
    echo "::error file=${path}::${label} must be a regular ${mode_description} Git blob"
    exit 1
  fi
  case " ${allowed_modes} " in
    *" ${mode} "*) ;;
    *)
      echo "::error file=${path}::${label} must be a regular ${mode_description} Git blob"
      exit 1
      ;;
  esac
  git -C "${repo}" cat-file blob "${object}" > "${destination}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_test_root_path() {
  local path="$1"
  if [[ "${path}" =~ ^Tests/ \
    || "${path}" =~ ^Packages/[^/]+/Tests/ \
    || "${path}" =~ ^Native/[^/]+/SwiftTests/ \
    || "${path}" =~ ^TerminalApp/(SoyehtTests|SoyehtMacTests)/ \
    || "${path}" =~ ^(Benchmarks|QA)/ ]]; then
    return 0
  fi
  return 1
}

is_reviewed_test_only_entry() {
  local path="$1" mode="$2" type="$3" object="$4" entry
  for entry in "${REVIEWED_TEST_ONLY_ENTRIES[@]}"; do
    if [[ "${path}|${mode}|${type}|${object}" == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

is_reviewed_automation_signal_entry() {
  local path="$1" mode="$2" type="$3" object="$4" entry
  for entry in "${REVIEWED_AUTOMATION_SIGNAL_ENTRIES[@]}"; do
    if [[ "${path}|${mode}|${type}|${object}" == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

is_reviewed_reference_only_entry() {
  local path="$1" mode="$2" type="$3" object="$4" entry
  for entry in "${REVIEWED_REFERENCE_ONLY_ENTRIES[@]}"; do
    if [[ "${path}|${mode}|${type}|${object}" == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

is_reviewed_external_code_entry() {
  local path="$1" mode="$2" type="$3" object="$4" entry
  for entry in "${REVIEWED_EXTERNAL_CODE_ENTRIES[@]}"; do
    if [[ "${path}|${mode}|${type}|${object}" == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

classify_reviewed_binary_entry() {
  local path="$1" mode="$2" type="$3" object="$4" entry entry_path
  reviewed_binary_path=0
  reviewed_binary_entry=0
  for entry in "${REVIEWED_BINARY_ENTRIES[@]}"; do
    entry_path="${entry%%|*}"
    if [[ "${path}" == "${entry_path}" ]]; then
      reviewed_binary_path=1
      if [[ "${path}|${mode}|${type}|${object}" == "${entry}" ]]; then
        reviewed_binary_entry=1
      fi
      return
    fi
  done
}

is_reviewed_binary_candidate_path() {
  local path="$1"
  case "${path}" in
    *.png|*.ttf|*.caf|\
    QA/runs/2026-04-18-wpl/report.md|\
    QA/runs/2026-05-05-mcpa-021-104/runner.py|\
    Sources/SwiftTerm/Documentation.docc/SSHIntegration.md)
      return 0
      ;;
  esac
  return 1
}

is_control_metadata_path() {
  local path="$1"
  [[ "${path}" == "${AUTOMATION_SIGNAL_BASELINE_REL}" \
    || "${path}" == "${BINARY_BASELINE_REL}" ]]
}

contains_external_code_resolution() {
  local path="$1" file="$2"
  case "${path}" in
    */Package.resolved|Package.resolved|*/Cargo.lock)
      return 0
      ;;
    */Cargo.toml)
      return 0
      ;;
    */Package.swift|Package.swift)
      return 0
      ;;
    *.pbxproj)
      return 0
      ;;
    scripts/fetch-engine.sh|scripts/theyos-engine.sha256|scripts/theyos-engine.version|\
    .github/workflows/macos-release.yml)
      return 0
      ;;
    .github/workflows/*.yml|.github/workflows/*.yaml)
      return 0
      ;;
    Makefile)
      return 0
      ;;
    *.sh|*.py|Makefile|CMakeLists.txt|*.cmake|*.rb|Fastfile|Podfile)
      grep -Eiq '(^|[;&|[:space:]])(curl|wget)([[:space:]]|$)|git[[:space:]]+(clone|fetch)' \
        "${file}"
      return
      ;;
  esac
  return 1
}

contains_non_shipping_automation_reference() {
  local file="$1" current_path="$2" match
  while IFS= read -r match; do
    if [[ "${match}" != "${current_path}" \
      && "${match}" != "${current_path##*/}" ]]; then
      return 0
    fi
  done < <(LC_ALL=C grep -F -o -f "${AUTOMATION_REFERENCE_PATTERNS}" \
    "${file}" 2>/dev/null || true)
  return 1
}

contains_reviewed_binary_reference() {
  grep -Fq -f "${BINARY_REFERENCE_PATTERNS}" "$1"
}

is_build_or_execution_input() {
  local path="$1"
  case "${path}" in
    *.sh|*.py|Makefile|CMakeLists.txt|*.cmake|*.rb|Fastfile|Podfile|\
    */Package.swift|Package.swift|*.pbxproj|*.xcconfig|\
    .github/workflows/*.yml|.github/workflows/*.yaml)
      return 0
      ;;
  esac
  return 1
}

is_named_opaque_binary_surface() {
  local path="$1"
  case "${path}" in
    *.xcframework|*.xcframework/*|*.framework|*.framework/*|\
    *.artifactbundle|*.artifactbundle/*|*.app|*.app/*|*.appex|*.appex/*|\
    *.xpc|*.xpc/*|*.bundle|*.bundle/*|*.a|*.o|*.dylib|*.so|*.wasm|\
    *.class|*.jar|*.aar|*.pyc|*.exe|*.dll|*.ipa)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

materialize_enumerated_blob() {
  local repo="$1" object="$2" mode="$3" type="$4" path="$5"
  local destination="$6" label="$7" allowed_modes="${8:-100644}"
  local mode_description
  mode_description="${allowed_modes// / or }"
  if [[ "${type}" != "blob" ]]; then
    echo "::error file=${path}::${label} must be a regular ${mode_description} Git blob"
    exit 1
  fi
  case " ${allowed_modes} " in
    *" ${mode} "*) ;;
    *)
      echo "::error file=${path}::${label} must be a regular ${mode_description} Git blob"
      exit 1
      ;;
  esac
  git -C "${repo}" cat-file blob "${object}" > "${destination}"
}

executable_magic_name() {
  local magic="$1"
  case "${magic}" in
    feedface*|cefaedfe*|feedfacf*|cffaedfe*) echo "Mach-O" ;;
    cafebabe*|bebafeca*|cafebabf*|bfbafeca*) echo "fat executable/class" ;;
    7f454c46*) echo "ELF" ;;
    213c617263683e0a*|213c7468696e3e*) echo "ar archive" ;;
    0061736d*) echo "WebAssembly" ;;
    4243c0de*|dec0170b*) echo "LLVM bitcode" ;;
    4d5a*) echo "PE executable" ;;
    6465780a*) echo "DEX executable" ;;
    *) return 1 ;;
  esac
}

is_utf8_text_blob() {
  local file="$1"
  [[ ! -s "${file}" ]] && return 0
  LC_ALL=C grep -Iq '' "${file}" || return 1
  iconv -f UTF-8 -t UTF-8 "${file}" >/dev/null 2>&1
}

is_external_content_pointer() {
  local file="$1"
  LC_ALL=C head -c 256 "${file}" \
    | LC_ALL=C grep -aEq \
      '^version https://git-lfs\.github\.com/spec/v1\r?$' \
    || return 1
  LC_ALL=C grep -aEq '^oid sha256:[0-9a-f]{64}\r?$' "${file}" \
    && LC_ALL=C grep -aEq '^size [0-9]+\r?$' "${file}"
}

is_sealed_path() {
  local path="$1" pair
  for pair in "${SEALED_PRE_EFFECT_BLOBS[@]}"; do
    if [[ "${path}" == "${pair%%:*}" ]]; then
      return 0
    fi
  done
  return 1
}

contains_runtime_signal() {
  local file="$1"
  if grep -Eiq "${DIRECT_PATTERN}" "${file}"; then
    return 0
  fi
  if grep -Eiq "${DOMAIN_PATTERN}" "${file}" \
    && grep -Eiq "${SECURITY_PATTERN}" "${file}"; then
    return 0
  fi
  if grep -Eiq "${DOMAIN_PATTERN}" "${file}" \
    && grep -Eiq '(^|[^[:alnum:]_])owner([^[:alnum:]_]|$)' "${file}" \
    && grep -Eiq '(^|[^[:alnum:]_])present([^[:alnum:]_]|$)' "${file}"; then
    return 0
  fi
  return 1
}

runtime_detected=0

AUTOMATION_BASELINE_FILE="${TMP_DIR}/automation-signal-baseline"
if ! materialize_regular_blob \
  "${IOS_DIR}" "${IOS_HEAD_SHA}" "${AUTOMATION_SIGNAL_BASELINE_REL}" \
  "${AUTOMATION_BASELINE_FILE}" "automation signal baseline"; then
  echo "Automation signal baseline is missing: ${AUTOMATION_SIGNAL_BASELINE_REL}"
  runtime_detected=1
else
  automation_index=0
  while IFS=$'\t' read -r baseline_path baseline_mode baseline_type \
    baseline_object baseline_extra; do
    [[ -z "${baseline_path}" ]] && continue
    if [[ -n "${baseline_extra:-}" \
      || "${baseline_mode}" != "100644" && "${baseline_mode}" != "100755" \
      || "${baseline_type}" != "blob" \
      || ! "${baseline_object}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "Invalid automation signal baseline entry: ${baseline_path}"
      runtime_detected=1
      continue
    fi
    if [[ "${automation_index}" -ge "${#SIGNAL_AUTOMATION_PATHS[@]}" \
      || "${baseline_path}" != "${SIGNAL_AUTOMATION_PATHS[automation_index]}" ]]; then
      echo "Automation signal baseline path set or order changed: ${baseline_path}"
      runtime_detected=1
    fi
    actual_entry="$(git -C "${IOS_DIR}" ls-tree \
      --format='%(objectmode) %(objecttype) %(objectname)' \
      "${IOS_HEAD_SHA}" -- ":(literal)${baseline_path}")"
    if [[ "${actual_entry}" \
      != "${baseline_mode} ${baseline_type} ${baseline_object}" ]]; then
      echo "Reviewed automation signal baseline changed: ${baseline_path}"
      runtime_detected=1
    fi
    REVIEWED_AUTOMATION_SIGNAL_ENTRIES+=(
      "${baseline_path}|${baseline_mode}|${baseline_type}|${baseline_object}"
    )
    automation_index=$((automation_index + 1))
  done < "${AUTOMATION_BASELINE_FILE}"
  if [[ "${automation_index}" != "${#SIGNAL_AUTOMATION_PATHS[@]}" \
    || "${automation_index}" != "18" ]]; then
    echo "Automation signal baseline must contain exactly 18 reviewed entries"
    runtime_detected=1
  fi
fi

BINARY_BASELINE_FILE="${TMP_DIR}/binary-baseline"
if ! materialize_regular_blob \
  "${IOS_DIR}" "${IOS_HEAD_SHA}" "${BINARY_BASELINE_REL}" \
  "${BINARY_BASELINE_FILE}" "reviewed binary baseline"; then
  echo "Reviewed binary baseline is missing: ${BINARY_BASELINE_REL}"
  runtime_detected=1
else
  if ! cmp -s "${BINARY_BASELINE_FILE}" \
    <(LC_ALL=C sort -u "${BINARY_BASELINE_FILE}"); then
    echo "Reviewed binary baseline must be sorted and unique"
    runtime_detected=1
  fi
  binary_baseline_count=0
  while IFS=$'\t' read -r baseline_path baseline_mode baseline_type \
    baseline_object baseline_extra; do
    [[ -z "${baseline_path}" ]] && continue
    if [[ -n "${baseline_extra:-}" \
      || "${baseline_mode}" != "100644" \
      || "${baseline_type}" != "blob" \
      || ! "${baseline_object}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "Invalid reviewed binary baseline entry: ${baseline_path}"
      runtime_detected=1
      continue
    fi
    case "${baseline_path}" in
      *.png|*.ttf|*.caf|\
      QA/runs/2026-04-18-wpl/report.md|\
      QA/runs/2026-05-05-mcpa-021-104/runner.py|\
      Sources/SwiftTerm/Documentation.docc/SSHIntegration.md) ;;
      *)
        echo "Reviewed binary baseline contains unsupported path: ${baseline_path}"
        runtime_detected=1
        ;;
    esac
    REVIEWED_BINARY_ENTRIES+=(
      "${baseline_path}|${baseline_mode}|${baseline_type}|${baseline_object}"
    )
    printf '%s\n%s\n' "${baseline_path}" "${baseline_path##*/}" \
      >> "${BINARY_REFERENCE_PATTERNS}"
    binary_baseline_count=$((binary_baseline_count + 1))
  done < "${BINARY_BASELINE_FILE}"
  if [[ "${binary_baseline_count}" != "208" ]]; then
    echo "Reviewed binary baseline must contain exactly 208 entries"
    runtime_detected=1
  fi
  LC_ALL=C sort -u -o "${BINARY_REFERENCE_PATTERNS}" \
    "${BINARY_REFERENCE_PATTERNS}"
fi

sealed_index=0
for pair in "${SEALED_PRE_EFFECT_BLOBS[@]}"; do
  sealed_path="${pair%%:*}"
  expected_blob="${pair#*:}"
  sealed_file="${TMP_DIR}/sealed-${sealed_index}"
  if ! materialize_regular_blob \
    "${IOS_DIR}" "${IOS_HEAD_SHA}" "${sealed_path}" "${sealed_file}" \
    "sealed owner-present PRE-EFFECT source"; then
    echo "Sealed owner-present PRE-EFFECT source is missing: ${sealed_path}"
    runtime_detected=1
  elif [[ "$(git hash-object "${sealed_file}")" != "${expected_blob}" ]]; then
    echo "Sealed owner-present PRE-EFFECT blob changed: ${sealed_path}"
    runtime_detected=1
  fi
  sealed_index=$((sealed_index + 1))
done

if [[ "${#REVIEWED_TEST_ONLY_ENTRIES[@]}" != "32" ]]; then
  echo "Reviewed test-only PRE-EFFECT baseline must contain exactly 32 entries"
  runtime_detected=1
fi
for entry in "${REVIEWED_TEST_ONLY_ENTRIES[@]}"; do
  IFS='|' read -r reviewed_path reviewed_mode reviewed_type reviewed_object \
    <<< "${entry}"
  if ! is_test_root_path "${reviewed_path}"; then
    echo "Reviewed PRE-EFFECT baseline path is not test-only: ${reviewed_path}"
    runtime_detected=1
  fi
  actual_entry="$(git -C "${IOS_DIR}" ls-tree \
    --format='%(objectmode) %(objecttype) %(objectname)' \
    "${IOS_HEAD_SHA}" -- ":(literal)${reviewed_path}")"
  if [[ "${actual_entry}" \
    != "${reviewed_mode} ${reviewed_type} ${reviewed_object}" ]]; then
    echo "Reviewed test-only PRE-EFFECT baseline changed: ${reviewed_path}"
    runtime_detected=1
  fi
done

candidate_index=0
while IFS= read -r -d '' record; do
  mode="${record%%$'\t'*}"
  remainder="${record#*$'\t'}"
  type="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  object="${remainder%%$'\t'*}"
  path="${remainder#*$'\t'}"
  [[ -z "${path}" ]] && continue
  is_sealed_path "${path}" && continue
  [[ "${path}" == "${PIN_REL}" ]] && continue
  is_control_metadata_path "${path}" && continue
  test_root=0
  reviewed_test_entry=0
  reviewed_automation_entry=0
  reviewed_reference_entry=0
  reviewed_external_entry=0
  reviewed_binary_entry=0
  reviewed_binary_path=0
  is_test_root_path "${path}" && test_root=1
  is_reviewed_test_only_entry "${path}" "${mode}" "${type}" "${object}" \
    && reviewed_test_entry=1
  is_reviewed_automation_signal_entry "${path}" "${mode}" "${type}" "${object}" \
    && reviewed_automation_entry=1
  is_reviewed_reference_only_entry "${path}" "${mode}" "${type}" "${object}" \
    && reviewed_reference_entry=1
  is_reviewed_external_code_entry "${path}" "${mode}" "${type}" "${object}" \
    && reviewed_external_entry=1
  if is_reviewed_binary_candidate_path "${path}"; then
    classify_reviewed_binary_entry "${path}" "${mode}" "${type}" "${object}"
  fi
  if [[ "${reviewed_binary_path}" == "1" \
    && "${reviewed_binary_entry}" != "1" ]]; then
    echo "Reviewed binary baseline changed: ${path}"
    runtime_detected=1
  fi
  if [[ "${type}" == "commit" || "${mode}" == "160000" ]]; then
    if [[ "${test_root}" == "1" && "${reviewed_test_entry}" == "1" ]]; then
      :
    else
      echo "Opaque shipping Gitlink detected: ${path}"
      runtime_detected=1
    fi
    continue
  fi
  if [[ "${type}" != "blob" || ( "${mode}" != "100644" && "${mode}" != "100755" ) ]]; then
    if [[ "${test_root}" == "1" && "${reviewed_test_entry}" == "1" ]]; then
      :
    else
      echo "Opaque non-regular shipping entry detected: ${path} (${mode} ${type})"
      runtime_detected=1
    fi
    continue
  fi
  candidate="${TMP_DIR}/candidate-${candidate_index}"
  materialize_enumerated_blob \
    "${IOS_DIR}" "${object}" "${mode}" "${type}" "${path}" "${candidate}" \
    "shipping ODB entry" "100644 100755"
  if is_external_content_pointer "${candidate}"; then
    echo "External Git LFS payload pointer detected: ${path}"
    runtime_detected=1
    candidate_index=$((candidate_index + 1))
    continue
  fi
  if is_named_opaque_binary_surface "${path}"; then
    echo "Shipping precompiled binary detected: ${path}"
    runtime_detected=1
    candidate_index=$((candidate_index + 1))
    continue
  fi
  prefix="$(od -An -tx1 -N16 "${candidate}" | tr -d '[:space:]')"
  if magic_name="$(executable_magic_name "${prefix}")"; then
    echo "Opaque ${magic_name} shipping blob detected: ${path}"
    runtime_detected=1
  elif is_utf8_text_blob "${candidate}"; then
    if contains_external_code_resolution "${path}" "${candidate}" \
      && [[ "${reviewed_external_entry}" != "1" \
        && "${reviewed_automation_entry}" != "1" ]]; then
      echo "Unreviewed external executable resolver detected: ${path}"
      runtime_detected=1
    fi
    if contains_runtime_signal "${candidate}" \
      && [[ "${reviewed_test_entry}" != "1" \
        && "${reviewed_automation_entry}" != "1" ]]; then
      echo "Shipping owner-present runtime signal detected: ${path}"
      runtime_detected=1
    fi
    if [[ "${reviewed_test_entry}" != "1" \
        && "${reviewed_automation_entry}" != "1" \
        && "${reviewed_reference_entry}" != "1" \
        && "${reviewed_external_entry}" != "1" ]] \
      && contains_non_shipping_automation_reference "${candidate}" "${path}"; then
      echo "Shipping input reaches reviewed non-shipping automation: ${path}"
      runtime_detected=1
    fi
    if is_build_or_execution_input "${path}" \
      && [[ "${reviewed_reference_entry}" != "1" \
        && "${reviewed_automation_entry}" != "1" \
        && "${reviewed_external_entry}" != "1" ]] \
      && contains_reviewed_binary_reference "${candidate}"; then
      echo "Shipping build input reaches reviewed binary payload: ${path}"
      runtime_detected=1
    fi
  elif [[ "${reviewed_binary_entry}" == "1" ]]; then
    :
  elif [[ "${test_root}" == "1" && "${reviewed_test_entry}" == "1" ]]; then
    :
  else
    echo "Opaque unclassified shipping blob detected: ${path}"
    runtime_detected=1
  fi
  candidate_index=$((candidate_index + 1))
done < <(git -C "${IOS_DIR}" ls-tree -rz \
  --format='%(objectmode)%x09%(objecttype)%x09%(objectname)%x09%(path)' \
  "${IOS_HEAD_SHA}")

MARKER="${TMP_DIR}/activation-marker"
marker_exists=1
if ! materialize_regular_blob \
  "${THEYOS_DIR}" "${THEYOS_HEAD_SHA}" "${MARKER_REL}" "${MARKER}" \
  "owner-present runtime activation marker"; then
  marker_exists=0
fi

if [[ "${runtime_detected}" == "0" && "${marker_exists}" == "0" ]]; then
  echo "iOS owner-present crossing remains PRE-EFFECT and closed."
  exit 0
fi
if [[ "${runtime_detected}" == "1" && "${marker_exists}" == "0" ]]; then
  echo "::error file=${MARKER_REL}::shipping owner-present code requires the ODB-verified activation marker"
  exit 1
fi

if [[ "$(jq -r '.contract' "${MARKER}")" != "soyeht-mobile-claw-vpn-owner-present-runtime-activation-v1" \
  || "$(jq -r '.version' "${MARKER}")" != "1" \
  || "$(jq -r '.error_wire.theyos_path' "${MARKER}")" != "${ERROR_SOURCE_REL}" \
  || "$(jq -r '.error_wire.ios_path' "${MARKER}")" != "${ERROR_VENDOR_REL}" ]]; then
  echo "::error file=${MARKER_REL}::activation marker shape or error-wire ownership paths are invalid"
  exit 1
fi
EXPECTED_SHA256="$(jq -r '.error_wire.sha256' "${MARKER}")"
if [[ ! "${EXPECTED_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "::error file=${MARKER_REL}::error-wire SHA-256 must be lowercase 64-hex"
  exit 1
fi

ERROR_SOURCE="${TMP_DIR}/error-source"
ERROR_VENDOR="${TMP_DIR}/error-vendor"
PIN_SOURCE="${TMP_DIR}/pin"
PINNED_ERROR="${TMP_DIR}/pinned-error"
if ! materialize_regular_blob \
  "${THEYOS_DIR}" "${THEYOS_HEAD_SHA}" "${ERROR_SOURCE_REL}" "${ERROR_SOURCE}" \
  "authoritative owner-present error wire"; then
  echo "::error file=${ERROR_SOURCE_REL}::activation marker requires the authoritative error-wire fixture"
  exit 1
fi
if ! materialize_regular_blob \
  "${IOS_DIR}" "${IOS_HEAD_SHA}" "${ERROR_VENDOR_REL}" "${ERROR_VENDOR}" \
  "iOS owner-present error-wire vendor"; then
  echo "::error file=${ERROR_VENDOR_REL}::activation marker requires the iOS error-wire vendor"
  exit 1
fi
if ! materialize_regular_blob \
  "${IOS_DIR}" "${IOS_HEAD_SHA}" "${PIN_REL}" "${PIN_SOURCE}" \
  "iOS cross-repo pin"; then
  echo "::error file=${PIN_REL}::activation marker requires the iOS cross-repo pin"
  exit 1
fi

PIN="$(grep -vE '^[[:space:]]*#' "${PIN_SOURCE}" | tr -d '[:space:]')"
if [[ ! "${PIN}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error file=${PIN_REL}::iOS cross-repo pin must be one lowercase 40-hex commit"
  exit 1
fi
if ! git -C "${THEYOS_DIR}" cat-file -e "${PIN}^{commit}" 2>/dev/null; then
  git -C "${THEYOS_DIR}" fetch --no-tags --depth=1 origin "${PIN}"
fi
if ! git -C "${THEYOS_DIR}" merge-base --is-ancestor "${PIN}" "${THEYOS_HEAD_SHA}" 2>/dev/null; then
  if [[ "$(git -C "${THEYOS_DIR}" rev-parse --is-shallow-repository)" == "true" ]]; then
    git -C "${THEYOS_DIR}" fetch --no-tags --unshallow origin
  else
    git -C "${THEYOS_DIR}" fetch --no-tags origin main
  fi
  if ! git -C "${THEYOS_DIR}" merge-base --is-ancestor "${PIN}" "${THEYOS_HEAD_SHA}"; then
    echo "::error file=${PIN_REL}::error-wire pin ${PIN} is not landed on theyos HEAD ${THEYOS_HEAD_SHA}"
    exit 1
  fi
fi
if ! materialize_regular_blob \
  "${THEYOS_DIR}" "${PIN}" "${ERROR_SOURCE_REL}" "${PINNED_ERROR}" \
  "error wire at the iOS pin"; then
  echo "::error file=${PIN_REL}::pin ${PIN} does not contain the owner-present error wire"
  exit 1
fi
if [[ "$(sha256_file "${ERROR_SOURCE}")" != "${EXPECTED_SHA256}" ]]; then
  echo "::error file=${MARKER_REL}::activation marker SHA-256 does not match authoritative error-wire bytes"
  exit 1
fi
if ! cmp -s "${ERROR_SOURCE}" "${PINNED_ERROR}" \
  || ! cmp -s "${ERROR_SOURCE}" "${ERROR_VENDOR}"; then
  echo "::error file=${ERROR_SOURCE_REL}::error-wire source, landed pin, and iOS vendor must be byte-identical"
  exit 1
fi

echo "iOS owner-present activation marker is backed by a landed, byte-identical error-wire contract."
