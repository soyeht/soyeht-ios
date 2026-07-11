#!/bin/bash
# Durable iOS crossing guard from the sealed PRE-EFFECT boundary to shipping runtime.
set -euo pipefail

IOS_DIR="${1:?usage: $0 SOYEHT_IOS_DIR THEYOS_DIR}"
THEYOS_DIR="${2:?usage: $0 SOYEHT_IOS_DIR THEYOS_DIR}"

MARKER_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_runtime_activation_v1.json"
ERROR_SOURCE_REL="admin/contracts/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
ERROR_VENDOR_REL="Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
PIN_REL="scripts/cross-repo-contract.sha"

# These are the reviewed, inert type/contract surfaces. Changing one is itself
# a crossing until the shared runtime marker and error contract are complete.
SEALED_PRE_EFFECT_BLOBS=(
  "Packages/SoyehtCore/Sources/SoyehtCore/API/MobileClawVPNOwnerPresentBoundary.swift:09892d9826cebe47755a24591bd2994c1166292f"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/MobileClawVPNDevE2EExecutionTupleV1.swift:b67e58e14544f1e2e29e57376f3239cbbdafb1d5"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalContextV2DTO.swift:c464ea12594657e3bbcf46121febc56e23b9897e"
  "Packages/SoyehtCore/Sources/SoyehtCore/WebAuthn/OwnerApprovalV2DTO.swift:c26db58cdc5c9e8dddfb98f21eda4c024ba5ac79"
)

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

is_explicit_non_shipping_path() {
  local path="$1" automation_path workflow_path
  if [[ "${path}" =~ ^Tests/ \
    || "${path}" =~ ^Packages/[^/]+/Tests/ \
    || "${path}" =~ ^Native/[^/]+/SwiftTests/ \
    || "${path}" =~ ^TerminalApp/(SoyehtTests|SoyehtMacTests)/ \
    || "${path}" =~ ^(Benchmarks|QA)/ ]]; then
    return 0
  fi
  for automation_path in "${NON_SHIPPING_AUTOMATION_PATHS[@]}"; do
    if [[ "${path}" == "${automation_path}" ]]; then
      return 0
    fi
  done
  for workflow_path in "${NON_SHIPPING_CI_WORKFLOW_PATHS[@]}"; do
    if [[ "${path}" == "${workflow_path}" ]]; then
      return 0
    fi
  done
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
  iconv -f UTF-8 -t UTF-8 "${file}" 2>/dev/null | cat >/dev/null
}

is_proven_passive_resource() {
  local path="$1" prefix="$2"
  case "${path}" in
    *.png) [[ "${prefix}" == 89504e470d0a1a0a* ]] ;;
    *.ttf) [[ "${prefix}" == 00010000* || "${prefix}" == 74727565* ]] ;;
    *.caf) [[ "${prefix}" == 63616666* ]] ;;
    *) return 1 ;;
  esac
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

candidate_index=0
while IFS= read -r -d '' record; do
  mode="${record%%$'\t'*}"
  remainder="${record#*$'\t'}"
  type="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  object="${remainder%%$'\t'*}"
  path="${remainder#*$'\t'}"
  [[ -z "${path}" ]] && continue
  is_explicit_non_shipping_path "${path}" && continue
  is_sealed_path "${path}" && continue
  [[ "${path}" == "${PIN_REL}" ]] && continue
  if [[ "${type}" == "commit" || "${mode}" == "160000" ]]; then
    echo "Opaque shipping Gitlink detected: ${path}"
    runtime_detected=1
    continue
  fi
  if [[ "${type}" != "blob" || ( "${mode}" != "100644" && "${mode}" != "100755" ) ]]; then
    echo "Opaque non-regular shipping entry detected: ${path} (${mode} ${type})"
    runtime_detected=1
    continue
  fi
  candidate="${TMP_DIR}/candidate-${candidate_index}"
  materialize_enumerated_blob \
    "${IOS_DIR}" "${object}" "${mode}" "${type}" "${path}" "${candidate}" \
    "shipping ODB entry" "100644 100755"
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
    if contains_runtime_signal "${candidate}"; then
      echo "Shipping owner-present runtime signal detected: ${path}"
      runtime_detected=1
    fi
  elif is_proven_passive_resource "${path}" "${prefix}"; then
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
